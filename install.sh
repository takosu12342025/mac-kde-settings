
set -euo pipefail

BIN=/usr/local/bin/mac-kde-settings
DESKTOP=/usr/share/applications/mac-kde-settings.desktop

refresh_desktop_db() {
    command -v update-desktop-database >/dev/null 2>&1 \
        && sudo update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
}

if [[ "${1:-}" == "--uninstall" ]]; then
    sudo rm -f "$BIN" "$DESKTOP"
    refresh_desktop_db
    echo "Uninstalled mac-kde-settings."
    exit 0
fi

echo "Installing mac-kde-settings..."

# ---- dependency check -------------------------------------------------------
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found." >&2; exit 1; }

if ! python3 - <<'CHECK' 2>/tmp/mks-dep-err.$$
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw
assert (Adw.get_major_version(), Adw.get_minor_version()) >= (1, 4), "libadwaita >= 1.4 is required"
assert (Gtk.get_major_version(), Gtk.get_minor_version()) >= (4, 10), "GTK >= 4.10 is required"
CHECK
then
    echo "ERROR: missing or outdated dependencies:" >&2
    sed 's/^/  /' /tmp/mks-dep-err.$$ >&2 || true
    rm -f /tmp/mks-dep-err.$$
    cat >&2 <<'HINT'

Install them with your package manager, e.g.:
  Arch      : sudo pacman -S python-gobject gtk4 libadwaita
  Debian/Ubuntu: sudo apt install python3-gi gir1.2-gtk-4.0 gir1.2-adw-1
  Fedora    : sudo dnf install python3-gobject gtk4 libadwaita
  openSUSE  : sudo zypper install python3-gobject typelib-1_0-Gtk-4_0 typelib-1_0-Adw-1
HINT
    exit 1
fi
rm -f /tmp/mks-dep-err.$$

if ! command -v kcmshell6 >/dev/null 2>&1 && ! command -v gnome-control-center >/dev/null 2>&1; then
    echo "WARNING: neither kcmshell6 (KDE Plasma 6) nor gnome-control-center (GNOME) found;" >&2
    echo "         most settings panels will not open." >&2
fi

# ---- build files in a temp dir, install atomically --------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/app" << 'PYEOF'
#!/usr/bin/env python3
import glob
import json
import locale
import os
import pwd
import re
import shutil
import subprocess
import threading
import time

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("Gsk", "4.0")
gi.require_version("Graphene", "1.0")
from gi.repository import Adw, Gdk, Gio, GLib, Graphene, Gsk, Gtk

# Seconds before the app restarts automatically after an update.
# Set to 0 to disable the automatic restart (the dialog is still shown).
AUTO_REBOOT_SEC = 10


# --------------------------------------------------------------------------- i18n
def detect_ja():
    for k in ("LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"):
        v = os.environ.get(k, "").split(":")[0].strip()
        if v and v not in ("C", "POSIX"):
            return v.lower().startswith("ja")
    try:
        return (locale.getlocale()[0] or "").lower().startswith("ja")
    except Exception:
        return False


IS_JA = detect_ja()

STR = {
    "app_title": ("システム設定", "System Settings"),
    "account": ("Account", "Account"),
    "wifi": ("Wi-Fi", "Wi-Fi"),
    "bt": ("Bluetooth", "Bluetooth"),
    "net": ("ネットワーク", "Network"),
    "bat": ("バッテリー", "Battery"),
    "gen": ("一般", "General"),
    "disp": ("ディスプレイ", "Displays"),
    "desk": ("デスクトップとDock", "Desktop & Dock"),
    "app": ("外観", "Appearance"),
    "wall": ("壁紙", "Wallpaper"),
    "wired_vpn": ("詳細ネットワーク・VPN", "Advanced Network & VPN"),
    "connected": ("接続済み", "Connected"),
    "disconnected": ("未接続", "Not Connected"),
    "cable_unplugged": ("ケーブル未接続", "Cable Unplugged"),
    "firewall": ("ファイアウォール", "Firewall"),
    "fw_active": ("動作中", "Active"),
    "fw_inactive": ("停止中", "Inactive"),
    "bt_devices": ("デバイス管理", "Device Management"),
    "power_profile": ("電源プロファイル", "Power Mode"),
    "low_power": ("低電力", "Low Power"),
    "auto_power": ("自動", "Automatic"),
    "high_power": ("高出力", "High Power"),
    "about": ("情報", "About"),
    "date_time": ("日付と時刻", "Date & Time"),
    "lang_region": ("言語と地域", "Language & Region"),
    "sw_update": ("ソフトウェアアップデート", "Software Update"),
    "storage": ("ストレージ", "Storage"),
    "keyboard": ("キーボード", "Keyboard"),
    "checking_upd": ("アップデートを確認中...", "Checking for Updates..."),
    "please_wait": ("しばらくお待ちください", "Please wait"),
    "upd_now": ("今すぐアップデート", "Update Now"),
    "upd_avail": ("アップデートが利用可能です", "Updates Available"),
    "detected_os": ("検出されたOS: {os}", "Detected OS: {os}"),
    "upd_count": ("{n}件の更新", "{n} Update(s)"),
    "upd_list_title": ("以下のアップデートがあります", "The following updates are available"),
    "up_to_date": ("お使いのシステムは最新です", "Your system is up to date"),
    "no_upd_sub": ("{os} に利用可能なアップデートはありません", "No updates available for {os}"),
    "installing_upd": ("アップデートをインストール中...", "Installing Updates..."),
    "wait_finish": ("完了するまでそのままお待ちください", "Please wait until installation completes"),
    "upd_done": ("アップデートが完了しました", "Updates Installed"),
    "upd_failed": ("アップデートに失敗しました", "Update Failed"),
    "upd_failed_sub": ("認証がキャンセルされたか、エラーが発生しました", "Authentication was cancelled or an error occurred"),
    "reboot_confirm": ("再起動しますか？", "Restart Required"),
    "reboot_body": (
        "アップデートを完了するため、{s}秒後に自動的に再起動します。",
        "Your computer will restart automatically in {s} seconds to complete the update.",
    ),
    "reboot_body_manual": ("アップデートを完了するには再起動が必要です。", "A restart is required to complete the update."),
    "reboot_later": ("後で再起動する", "Restart Later"),
    "reboot_now": ("今すぐ再起動", "Restart Now"),
    "reboot_postponed": ("再起動は延期されました", "Restart postponed"),
    "used_of": ("{used:.2f} GB / {total:.2f} GB 使用中", "{used:.2f} GB of {total:.2f} GB used"),
    "free_gb": ("{n:.2f} GB 空き", "{n:.2f} GB free"),
    "used": ("使用済み", "Used"),
    "calculating": ("計算中…", "Calculating…"),
    "system": ("システム", "System"),
    "documents": ("書類", "Documents"),
    "apps": ("アプリ", "Apps"),
    "media": ("メディア", "Media"),
    "others": ("その他", "Others"),
    "disk_manage": ("ディスクと自動マウント設定", "Disks & Auto-Mount"),
    "disp_res": ("ディスプレイ解像度・倍率", "Resolution & Scale"),
    "night_shift": ("Night Shift（夜間カラー）", "Night Shift"),
    "anim_speed": ("アニメーション速度", "Animation Speed"),
    "left_buttons": ("タイトルバーボタンを左側に配置", "Place Titlebar Buttons on Left"),
    "dock_settings": ("Dockの設定", "Dock Settings"),
    "dock_sub": ("すべてのパネルの設定を開く", "Open panel edit mode"),
    "app_mode": ("外観モード", "Appearance Mode"),
    "color_scheme": ("カラースキーム", "Color Scheme"),
    "light": ("ライト", "Light"),
    "dark": ("ダーク", "Dark"),
    "accent_theme": ("アクセントカラー・テーマ詳細", "Accent Color & Theme"),
    "desk_wall": ("デスクトップの壁紙", "Desktop Wallpaper"),
    "choose_img": ("画像を選ぶ...", "Choose Image..."),
    "images": ("画像", "Images"),
    "cmd_missing": ("{cmd} が見つかりません", "{cmd} not found"),
    "back": ("戻る", "Back"),
    "forward": ("進む", "Forward"),
    "anim_enable": ("アニメーションを有効にする", "Enable Animations"),
    "dock_sub_gnome": ("Dockの拡張機能の設定を開く", "Open dock extension preferences"),
    "no_dock": ("Dockの拡張機能が見つかりません", "No dock extension found"),
}


def T(key, **kw):
    pair = STR.get(key, (key, key))
    s = pair[0] if IS_JA else pair[1]
    return s.format(**kw) if kw else s


def esc(text):
    return GLib.markup_escape_text(str(text))


GLib.set_application_name(T("app_title"))


# --------------------------------------------------------------------------- desktop environment
def detect_de():
    """Return 'kde' or 'gnome'. Override with MAC_SETTINGS_DE=kde|gnome."""
    forced = os.environ.get("MAC_SETTINGS_DE", "").lower()
    if forced in ("kde", "gnome"):
        return forced
    raw = (os.environ.get("XDG_CURRENT_DESKTOP") or os.environ.get("DESKTOP_SESSION") or "").lower()
    toks = {t for t in re.split(r"[:;\s]+", raw) if t}
    if toks & {"kde", "plasma"}:
        return "kde"
    if toks & {"ubuntu", "unity", "zorin"} or any(t.startswith("gnome") for t in toks):
        return "gnome"
    if shutil.which("kcmshell6"):
        return "kde"
    if shutil.which("gnome-control-center"):
        return "gnome"
    return "kde"


DE = detect_de()

# key -> how to open it per desktop. GNOME panel names are tried in order
# (desktop-file ids differ between GNOME versions), then gnome-control-center <name>.
PANELS = {
    "users": {"kde": "kcm_users", "gnome": ("users",)},
    "about": {"kde": "kcm_about-distro", "gnome": ("about", "info-overview", "system")},
    "clock": {"kde": "kcm_clock", "gnome": ("datetime", "system")},
    "region": {"kde": "kcm_regionandlang", "gnome": ("region", "system")},
    "keyboard": {"kde": "kcm_keyboard", "gnome": ("keyboard",)},
    "display": {"kde": "kcm_kscreen", "gnome": ("display",)},
    "nightlight": {"kde": "kcm_nightlight", "gnome": ("display", "color")},
    "colors": {"kde": "kcm_colors", "gnome": ("appearance", "background")},
    "network": {"kde": "kcm_networkmanagement", "gnome": ("network", "wifi")},
    "bluetooth": {"kde": "kcm_bluetooth", "gnome": ("bluetooth",)},
    "ubuntu_dock": {"kde": "", "gnome": ("ubuntu", "appearance", "background")},
    "firewall": {"kde": "kcm_firewall", "gnome_cmds": [["gufw"], ["firewall-config"]]},
    "disks": {"kde": "kcm_device_automounter", "gnome_cmds": [["gnome-disks"]]},
}


# --------------------------------------------------------------------------- helpers
def ui(fn, *args):
    """Run fn(*args) once on the GTK main thread."""
    GLib.idle_add(lambda: (fn(*args), False)[1])


def out(cmd, timeout=3):
    """Run a command and return stripped stdout ('' on any failure)."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def run_seq(cmds, on_done=None):
    """Run commands one after another in a background thread (UI never blocks)."""
    def worker():
        rc = 0
        for c in cmds:
            try:
                rc = subprocess.run(c, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
            except OSError:
                rc = 127
        if on_done:
            ui(on_done, rc)
    threading.Thread(target=worker, daemon=True).start()


def kread(file, group, key, default=""):
    return out(["kreadconfig6", "--file", file, "--group", group, "--key", key, "--default", default])


def kwrite_cmd(file, group, key, value):
    return ["kwriteconfig6", "--file", file, "--group", group, "--key", key, str(value)]


KWIN_RECONFIGURE = ["qdbus6", "org.kde.KWin", "/KWin", "reconfigure"]


def gget(schema, key):
    return out(["gsettings", "get", schema, key]).strip("'")


def gset_cmd(schema, key, value):
    return ["gsettings", "set", schema, key, str(value)]


def fmt_size(b):
    g = b / 1024 ** 3
    return f"{g:.1f} GB" if g >= 1 else f"{b / 1024 ** 2:.0f} MB"


CSS = """
.badge { min-width: 28px; min-height: 28px; border-radius: 7px; }
.badge image { color: #ffffff; }
.badge-blue { background-color: #1c71d8; }
.badge-orange { background-color: #e66100; }
"""
SEG_COLORS = ["#e01b24", "#ff7800", "#f6d32d", "#77767b", "#33d17a", "#3584e4"]


class SegBar(Gtk.DrawingArea):
    """Multi-colour storage bar rendered with GTK4's DrawingArea/Cairo."""

    def __init__(self, segs, total):
        super().__init__()
        self.segs = [(SEG_COLORS[i], b) for i, b, _ in segs if b > 0]
        self.total = max(0, total)
        self.set_content_height(24)
        self.set_hexpand(True)
        self.set_draw_func(self._draw_bar)

    def _draw_bar(self, area, cr, width, height):
        if width <= 0 or height <= 0:
            return
        # Rounded background track and clipping path.
        radius = min(6.0, height / 2.0, width / 2.0)
        cr.new_path()
        cr.arc(radius, radius, radius, 3.14159265, 4.71238898)
        cr.arc(width - radius, radius, radius, 4.71238898, 6.28318531)
        cr.arc(width - radius, height - radius, radius, 0.0, 1.57079633)
        cr.arc(radius, height - radius, radius, 1.57079633, 3.14159265)
        cr.close_path()
        cr.set_source_rgba(0.5, 0.5, 0.5, 0.25)
        cr.fill_preserve()
        cr.clip()

        if self.total <= 0:
            return

        x = 0.0
        for color, amount in self.segs:
            if amount <= 0 or x >= width:
                continue
            segment_width = min(width - x, width * amount / self.total)
            if segment_width <= 0:
                continue
            rgba = Gdk.RGBA()
            if not rgba.parse(color):
                continue
            cr.set_source_rgba(rgba.red, rgba.green, rgba.blue, rgba.alpha)
            cr.rectangle(x, 0, segment_width, height)
            cr.fill()
            x += segment_width


def install_css():
    prov = Gtk.CssProvider()
    if hasattr(prov, "load_from_string"):  # GTK >= 4.12
        prov.load_from_string(CSS)
    else:
        prov.load_from_data(CSS.encode())
    Gtk.StyleContext.add_provider_for_display(
        Gdk.Display.get_default(), prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
    )


class HistoryControls(Adw.Bin):
    """Back / Forward buttons, same layout as the NautilusHistoryControls template:
    a horizontal box (spacing 6) with two buttons bound to the actions
    slot.back / slot.forward. Right-click or long-press on a button opens the
    history menu (handlers named like in the template)."""
    __gtype_name__ = "MksHistoryControls"

    def __init__(self, app):
        super().__init__()
        self.app = app
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)

        self.back_button = Gtk.Button(icon_name="go-previous-symbolic",
                                      action_name="slot.back", tooltip_text=T("back"))
        right = Gtk.GestureClick(button=3)  # right click
        right.connect("pressed", self.on_back_button_right_click)
        press = Gtk.GestureLongPress()      # long press
        press.connect("pressed", self.on_back_button_long_press)
        self.back_button.add_controller(right)
        self.back_button.add_controller(press)

        self.forward_button = Gtk.Button(icon_name="go-next-symbolic",
                                         action_name="slot.forward", tooltip_text=T("forward"))
        right = Gtk.GestureClick(button=3)
        right.connect("pressed", self.on_forward_button_right_click)
        press = Gtk.GestureLongPress()
        press.connect("pressed", self.on_forward_button_long_press)
        self.forward_button.add_controller(right)
        self.forward_button.add_controller(press)

        box.append(self.back_button)
        box.append(self.forward_button)
        self.set_child(box)

    def _popup(self, gesture, button, back):
        gesture.set_state(Gtk.EventSequenceState.CLAIMED)  # don't also trigger a click
        self.app.history_popup(button, back)

    def on_back_button_right_click(self, gesture, _n_press, _x, _y):
        self._popup(gesture, self.back_button, True)

    def on_back_button_long_press(self, gesture, _x, _y):
        self._popup(gesture, self.back_button, True)

    def on_forward_button_right_click(self, gesture, _n_press, _x, _y):
        self._popup(gesture, self.forward_button, False)

    def on_forward_button_long_press(self, gesture, _x, _y):
        self._popup(gesture, self.forward_button, False)


# --------------------------------------------------------------------------- app
class App(Adw.Application):
    def __init__(self):
        super().__init__(application_id="com.local.KdeSet")
        self._bd_cache = None
        self._anim_src = 0
        self._lock = False  # True while we change the sidebar selection ourselves
        # Same model as Nautilus' window slot: current location + two lists,
        # most recent first.
        self.cur = None
        self.back_list = []
        self.forward_list = []

    # ---- generic utilities -------------------------------------------------
    def toast(self, msg):
        self.toasts.add_toast(Adw.Toast(title=msg))

    def spawn(self, cmd):
        if not shutil.which(cmd[0]):
            self.toast(T("cmd_missing", cmd=cmd[0]))
            return
        try:
            p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            threading.Thread(target=p.wait, daemon=True).start()  # reap, avoid zombies
        except OSError as e:
            self.toast(str(e))

    def open_panel(self, key):
        spec = PANELS[key]
        if DE == "kde":
            self.spawn(["kcmshell6", spec["kde"]])
            return
        if "gnome_cmds" in spec:
            for c in spec["gnome_cmds"]:
                if shutil.which(c[0]):
                    self.spawn(c)
                    return
            self.toast(T("cmd_missing", cmd=spec["gnome_cmds"][0][0]))
            return
        for name in spec["gnome"]:
            for fmt in ("org.gnome.Settings-{}-panel.desktop", "gnome-{}-panel.desktop"):
                info = Gio.DesktopAppInfo.new(fmt.format(name))
                if info:
                    try:
                        info.launch([], None)
                        return
                    except GLib.Error:
                        pass
        self.spawn(["gnome-control-center", spec["gnome"][0]])

    def open_dock(self):
        if DE == "kde":
            self.spawn([
                "qdbus6", "org.kde.plasmashell", "/PlasmaShell",
                "org.freedesktop.DBus.Properties.Set", "org.kde.PlasmaShell", "editMode", "true",
            ])
            return
        exts = out(["gnome-extensions", "list", "--enabled"]).split()
        for uuid in ("dash-to-dock@micxgx.gmail.com", "dash-to-panel@jderose9.github.com"):
            if uuid in exts:
                self.spawn(["gnome-extensions", "prefs", uuid])
                return
        if "ubuntu-dock@ubuntu.com" in exts:
            self.open_panel("ubuntu_dock")
            return
        self.toast(T("no_dock"))
        for app in ("gnome-extensions-app", "extension-manager"):
            if shutil.which(app):
                self.spawn([app])
                return

    # ---- navigation history: port of Nautilus (nautilus-window-slot.c) -------
    # Model: current location + back_list + forward_list (most recent first).
    #  * open a new location (update_history, STANDARD): current -> back_list,
    #    forward_list is cleared.
    #  * back_or_forward(back, distance) (handle_go_direction): current and the
    #    `distance` nearer entries move to the opposite list, the next entry
    #    becomes the current location.
    # Locations: ("page", pid) | ("storage",) | ("update",)
    def _loc_title(self, loc):
        if loc[0] == "page":
            return self.row_map[loc[1]].pt
        return T("storage") if loc[0] == "storage" else T("sw_update")

    def nav_header(self):
        hb = Adw.HeaderBar(show_back_button=False)
        hb.pack_start(HistoryControls(self))
        return hb

    def history_popup(self, btn, back):
        lst = self.back_list if back else self.forward_list
        if not lst:
            return
        pop = Gtk.Popover()
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        for idx, loc in enumerate(lst[:15]):
            b = Gtk.Button()
            b.add_css_class("flat")
            b.set_child(Gtk.Label(label=self._loc_title(loc), xalign=0))
            b.connect("clicked", lambda _b, i=idx: (pop.popdown(), self.back_or_forward(back, i)))
            box.append(b)
        pop.set_child(box)
        pop.set_parent(btn)
        pop.connect("closed", lambda p: GLib.idle_add(lambda: (p.unparent(), False)[1]))
        pop.popup()

    def _sync_nav(self):
        self.act_back.set_enabled(bool(self.back_list))
        self.act_fwd.set_enabled(bool(self.forward_list))

    def navigate(self, loc):
        if loc == self.cur:
            return
        if self.cur is not None:
            self.back_list.insert(0, self.cur)  # current -> back list
        self.forward_list.clear()               # clobber the forward list
        self.cur = loc
        self._show(loc)
        self._sync_nav()

    def back_or_forward(self, back, distance=0):
        lst, other = (self.back_list, self.forward_list) if back else (self.forward_list, self.back_list)
        if distance >= len(lst):
            return
        other.insert(0, self.cur)               # current location -> other list
        for _ in range(distance):               # extra links -> other list
            other.insert(0, lst.pop(0))
        self.cur = lst.pop(0)                   # next entry becomes the location
        self._show(self.cur)
        self._sync_nav()

    def _show(self, loc):
        kind = loc[0]
        pid = loc[1] if kind == "page" else "gen"
        row = self.row_map[pid]
        self._lock = True
        try:
            self.cnav.pop_to_page(self.cp)
            self.sl.select_row(row)
            self.st.set_visible_child_name(pid)
            self.cp.set_title(row.pt)
        finally:
            self._lock = False
        if pid == "net":
            self.refresh_net()
        if kind == "storage":
            self._push_storage()
        elif kind == "update":
            self._push_update()

    @staticmethod
    def has_power_page():
        return bool(glob.glob("/sys/class/power_supply/BAT*")) or bool(shutil.which("powerprofilesctl"))

    # ---- window ------------------------------------------------------------
    def do_activate(self):
        win = self.props.active_window
        if win:  # already running: just raise the existing window
            win.present()
            return

        install_css()
        self.w = Adw.ApplicationWindow(
            application=self, default_width=820, default_height=560, title=T("app_title")
        )

        # Back / Forward: actions drive the buttons' enabled state (like Nautilus)
        self.act_back = Gio.SimpleAction.new("back", None)
        self.act_back.connect("activate", lambda *_: self.back_or_forward(True))
        self.act_fwd = Gio.SimpleAction.new("forward", None)
        self.act_fwd.connect("activate", lambda *_: self.back_or_forward(False))
        slot = Gio.SimpleActionGroup()  # actions referenced as slot.back / slot.forward
        slot.add_action(self.act_back)
        slot.add_action(self.act_fwd)
        self.w.insert_action_group("slot", slot)
        keys = Gtk.ShortcutController()
        keys.set_scope(Gtk.ShortcutScope.GLOBAL)
        for trigger, name in (("<Alt>Left", "slot.back"), ("<Alt>Right", "slot.forward")):
            keys.add_shortcut(Gtk.Shortcut.new(Gtk.ShortcutTrigger.parse_string(trigger),
                                               Gtk.NamedAction.new(name)))
        self.w.add_controller(keys)

        # mouse side buttons: 8 = back, 9 = forward
        click = Gtk.GestureClick(button=0)
        click.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)

        def on_click(gesture, _n, _x, _y):
            b = gesture.get_current_button()
            if b == 8:
                self.back_or_forward(True)
            elif b == 9:
                self.back_or_forward(False)

        click.connect("pressed", on_click)
        self.w.add_controller(click)

        sv = Adw.NavigationSplitView()
        self.toasts = Adw.ToastOverlay()
        self.toasts.set_child(sv)
        self.w.set_content(self.toasts)

        self.st = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE)

        items = [
            ("wifi", T("wifi"), "network-wireless-symbolic", self.p_wifi),
            ("bt", T("bt"), "bluetooth-symbolic", self.p_bt),
            ("net", T("net"), "network-wired-symbolic", self.p_net),
            ("bat", T("bat"), "battery-good-symbolic", self.p_bat),
            ("gen", T("gen"), "preferences-system-symbolic", self.p_gen),
            ("disp", T("disp"), "video-display-symbolic", self.p_disp),
            ("desk", T("desk"), "user-desktop-symbolic", self.p_desk),
            ("app", T("app"), "preferences-desktop-theme-symbolic", self.p_app),
            ("wall", T("wall"), "preferences-desktop-wallpaper-symbolic", self.p_wall),
        ]
        if not self.has_power_page():
            items = [i for i in items if i[0] != "bat"]

        sp = Adw.NavigationPage(title=T("app_title"))
        stv = Adw.ToolbarView()
        stv.add_top_bar(Adw.HeaderBar())
        sc = Gtk.ScrolledWindow()
        sc.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.sl = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self.sl.add_css_class("navigation-sidebar")
        self.sl.connect("row-selected", self.on_sel)

        # account row
        pw = pwd.getpwuid(os.getuid())
        uname = (pw.pw_gecos.split(",")[0] if pw.pw_gecos else "") or pw.pw_name
        ur = Gtk.ListBoxRow()
        ur.kcm = "users"
        ub = Gtk.Box(spacing=12, margin_top=6, margin_bottom=6)
        av = Adw.Avatar(size=38, text=uname, show_initials=True)
        face = os.path.join(pw.pw_dir, ".face.icon")
        if os.path.exists(face):
            try:
                av.set_custom_image(Gdk.Texture.new_from_filename(face))
            except GLib.Error:
                pass
        utb = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, valign=Gtk.Align.CENTER)
        l1 = Gtk.Label(label=uname, xalign=0)
        l1.add_css_class("heading")
        l2 = Gtk.Label(label=T("account"), xalign=0)
        l2.add_css_class("caption")
        l2.add_css_class("dim-label")
        utb.append(l1)
        utb.append(l2)
        ub.append(av)
        ub.append(utb)
        ur.set_child(ub)
        self.sl.append(ur)

        self.row_map = {}
        for pid, title, icon, builder in items:
            self.st.add_named(builder(), pid)
            r = Gtk.ListBoxRow()
            r.pid = pid
            r.pt = title
            b = Gtk.Box(spacing=12)
            b.append(Gtk.Image.new_from_icon_name(icon))
            b.append(Gtk.Label(label=title, xalign=0))
            r.set_child(b)
            self.sl.append(r)
            self.row_map[pid] = r

        sc.set_child(self.sl)
        stv.set_content(sc)
        sp.set_child(stv)
        sv.set_sidebar(sp)

        self.cnav = Adw.NavigationView()
        self.cp = Adw.NavigationPage(title=T("gen"))
        ctv = Adw.ToolbarView()
        ctv.add_top_bar(self.nav_header())
        ctv.set_content(self.st)
        self.cp.set_child(ctv)
        self.cnav.push(self.cp)
        sv.set_content(Adw.NavigationPage(title=T("gen"), child=self.cnav))

        self.navigate(("page", "gen"))
        self.w.present()

    def on_sel(self, lb, r):
        if not r or self._lock:
            return
        if hasattr(r, "kcm"):
            self.open_panel(r.kcm)
            cur = self.st.get_visible_child_name()
            if cur in self.row_map:
                self._lock = True
                lb.select_row(self.row_map[cur])
                self._lock = False
        elif hasattr(r, "pid"):
            self.navigate(("page", r.pid))

    def krow(self, t, m, s=""):
        r = Adw.ActionRow(title=esc(t), subtitle=esc(s) if s else "", activatable=True)
        r.add_suffix(Gtk.Image.new_from_icon_name("go-next-symbolic"))
        if m == "update":
            r.connect("activated", lambda _: self.navigate(("update",)))
        elif m == "storage":
            r.connect("activated", lambda _: self.navigate(("storage",)))
        else:
            r.connect("activated", lambda _: self.open_panel(m))
        return r

    @staticmethod
    def get_os_info():
        d = {}
        try:
            with open("/etc/os-release") as f:
                for l in f:
                    if "=" in l:
                        k, v = l.strip().split("=", 1)
                        d[k] = v.strip("\"'")
        except OSError:
            pass
        oid = d.get("ID", "linux").lower()
        like = d.get("ID_LIKE", "").lower()
        pretty = d.get("PRETTY_NAME") or d.get("NAME") or "Linux"
        return oid, like, pretty

    def pm_kind(self):
        oid, like, _ = self.get_os_info()
        ids = {oid, *like.split()}
        if ids & {"arch", "manjaro", "endeavouros", "cachyos", "garuda"}:
            return "arch"
        if ids & {"debian", "ubuntu", "linuxmint", "pop"}:
            return "debian"
        if ids & {"fedora", "rhel", "centos", "rocky", "almalinux"}:
            return "fedora"
        if ids & {"suse", "opensuse", "opensuse-leap", "opensuse-tumbleweed", "sles"}:
            return "suse"
        return "other"

    # ---- Wi-Fi / Bluetooth / Battery --------------------------------------
    def p_wifi(self):
        p = Adw.PreferencesPage()
        g = Adw.PreferencesGroup()
        have = bool(shutil.which("nmcli"))
        s = Adw.SwitchRow(title=esc(T("wifi")), sensitive=have)
        s.set_active(out(["nmcli", "radio", "wifi"]) == "enabled")
        s.connect(
            "notify::active",
            lambda x, _: run_seq([["nmcli", "radio", "wifi", "on" if x.get_active() else "off"]]),
        )
        g.add(s)
        g.add(self.krow(T("wired_vpn"), "network"))
        p.add(g)
        return p

    def p_bt(self):
        p = Adw.PreferencesPage()
        g = Adw.PreferencesGroup()
        have = bool(shutil.which("bluetoothctl"))
        s = Adw.SwitchRow(title=esc(T("bt")), sensitive=have)
        s.set_active("Powered: yes" in out(["bluetoothctl", "show"]))
        s.connect(
            "notify::active",
            lambda x, _: run_seq([["bluetoothctl", "power", "on" if x.get_active() else "off"]]),
        )
        g.add(s)
        g.add(self.krow(T("bt_devices"), "bluetooth"))
        p.add(g)
        return p

    def p_bat(self):
        p = Adw.PreferencesPage()
        g = Adw.PreferencesGroup()
        r = Adw.ActionRow(title=esc(T("power_profile")))
        b = Gtk.Box(valign=Gtk.Align.CENTER)
        b.add_css_class("linked")
        b1 = Gtk.ToggleButton(label=T("low_power"))
        b2 = Gtk.ToggleButton(label=T("auto_power"), group=b1)
        b3 = Gtk.ToggleButton(label=T("high_power"), group=b1)
        modes = [(b1, "power-saver"), (b2, "balanced"), (b3, "performance")]
        cur = out(["powerprofilesctl", "get"]) or "balanced"
        for btn, mode in modes:
            btn.set_active(mode == cur)
            btn.set_sensitive(bool(shutil.which("powerprofilesctl")))
        for btn, mode in modes:
            btn.connect(
                "toggled",
                lambda t, m=mode: t.get_active() and run_seq([["powerprofilesctl", "set", m]]),
            )
            b.append(btn)
        r.add_suffix(b)
        g.add(r)
        p.add(g)
        return p

    # ---- Network -----------------------------------------------------------
    def p_net(self):
        p = Adw.PreferencesPage()
        self.net_grp = Adw.PreferencesGroup()
        p.add(self.net_grp)
        self.net_rows = []
        g2 = Adw.PreferencesGroup()
        g2.add(self.krow(T("wired_vpn"), "network"))
        p.add(g2)
        self.refresh_net()
        return p

    @staticmethod
    def _badge_icon(icon_name, color_class):
        box = Gtk.Box(halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER)
        box.set_size_request(28, 28)
        box.add_css_class("badge")
        box.add_css_class(color_class)
        img = Gtk.Image.new_from_icon_name(icon_name)
        img.set_pixel_size(16)
        img.set_halign(Gtk.Align.CENTER)
        img.set_valign(Gtk.Align.CENTER)
        img.set_hexpand(True)
        img.set_vexpand(True)
        box.append(img)
        return box

    @staticmethod
    def _detect_net_states():
        eth_present = eth_up = wifi_present = wifi_up = False
        for line in out(["nmcli", "-t", "-f", "TYPE,STATE", "device"]).splitlines():
            parts = line.split(":")
            if len(parts) >= 2:
                dtype, state = parts[0].strip(), parts[1].strip().lower()
                if dtype == "ethernet":
                    eth_present = True
                    eth_up = eth_up or state.startswith("connected")
                elif dtype == "wifi":
                    wifi_present = True
                    wifi_up = wifi_up or state.startswith("connected")

        if not eth_present and not wifi_present and os.path.isdir("/sys/class/net"):
            for iface in os.listdir("/sys/class/net"):
                if iface == "lo":
                    continue
                try:
                    with open(f"/sys/class/net/{iface}/operstate") as f:
                        is_up = f.read().strip() == "up"
                except OSError:
                    is_up = False
                if os.path.isdir(f"/sys/class/net/{iface}/wireless"):
                    wifi_present = True
                    wifi_up = wifi_up or is_up
                else:
                    eth_present = True
                    eth_up = eth_up or is_up

        fw_up = any(out(["systemctl", "is-active", s]) == "active"
                    for s in ("ufw", "firewalld", "nftables", "iptables"))
        if not fw_up:
            try:
                with open("/etc/ufw/ufw.conf") as f:
                    fw_up = "ENABLED=yes" in f.read()
            except OSError:
                pass
        return eth_present, eth_up, wifi_present, wifi_up, fw_up

    def refresh_net(self):
        def work():
            ui(self._render_net, *self._detect_net_states())
        threading.Thread(target=work, daemon=True).start()

    def _render_net(self, eth_p, eth_up, wifi_p, wifi_up, fw_up):
        for r in self.net_rows:
            self.net_grp.remove(r)
        self.net_rows.clear()

        def row(title, icon, badge, is_on, on_text, off_text, cb):
            dot = "#2ec27e" if is_on else "#9a9996"
            sub = f'<span foreground="{dot}">●</span> {esc(on_text if is_on else off_text)}'
            r = Adw.ActionRow(title=esc(title), subtitle=sub, use_markup=True, activatable=True)
            r.add_prefix(self._badge_icon(icon, badge))
            r.add_suffix(Gtk.Image.new_from_icon_name("go-next-symbolic"))
            r.connect("activated", cb)
            self.net_grp.add(r)
            self.net_rows.append(r)

        if eth_p or not wifi_p:
            row("Ethernet", "network-wired-symbolic", "badge-blue", eth_up,
                T("connected"), T("cable_unplugged"),
                lambda _: self.open_panel("network"))
        if wifi_p:
            row(T("wifi"), "network-wireless-symbolic", "badge-blue", wifi_up,
                T("connected"), T("disconnected"),
                lambda _: self.sl.select_row(self.row_map["wifi"]))
        row(T("firewall"), "security-high-symbolic", "badge-orange", fw_up,
            T("fw_active"), T("fw_inactive"),
            lambda _: self.open_panel("firewall"))

    # ---- Storage -----------------------------------------------------------
    def _get_drives(self):
        _, _, pretty_os = self.get_os_info()
        drives, seen = [], set()
        try:
            data = json.loads(subprocess.check_output(
                ["lsblk", "-J", "-b", "-o", "NAME,LABEL,MODEL,MOUNTPOINT,SIZE,TYPE"],
                text=True, stderr=subprocess.DEVNULL, timeout=5))

            def walk(devs, parent_model=""):
                for d in devs:
                    model = (d.get("model") or parent_model or "").strip()
                    mp = d.get("mountpoint") or ""
                    label = (d.get("label") or "").strip()
                    if mp and (mp == "/" or mp.startswith(("/media/", "/run/media/", "/mnt/"))):
                        try:
                            st = os.statvfs(mp)
                            key = (st.f_blocks, st.f_bfree, st.f_frsize)
                            if key not in seen:
                                seen.add(key)
                                total = st.f_blocks * st.f_frsize
                                avail = st.f_bavail * st.f_frsize
                                free = st.f_bfree * st.f_frsize
                                used = max(0, total - free)
                                name = label or model or ("System Disk" if mp == "/" else os.path.basename(mp))
                                drives.append((name, mp, total, used, avail))
                        except OSError:
                            pass
                    if "children" in d:
                        walk(d["children"], model)

            walk(data.get("blockdevices", []))
        except Exception:
            pass
        if not drives:
            st = os.statvfs("/")
            total = st.f_blocks * st.f_frsize
            avail = st.f_bavail * st.f_frsize
            used = max(0, total - st.f_bfree * st.f_frsize)
            drives.append(("System Disk", "/", total, used, avail))
        return drives, pretty_os

    def _storage_breakdown(self, used, progress=None):
        """Real per-category usage of the root filesystem (runs in a thread).
        progress(partial_dict) is called after each category."""
        if self._bd_cache and time.time() - self._bd_cache[0] < 300:
            return self._bd_cache[1]
        home = os.path.expanduser("~")
        groups = {  # quick ones first so the bar fills in early
            "documents": [f"{home}/Documents", f"{home}/Downloads", f"{home}/Desktop"],
            "media": [f"{home}/Pictures", f"{home}/Music", f"{home}/Videos"],
            "apps": ["/opt", "/var/lib/flatpak", "/var/lib/snapd", f"{home}/.local/share/flatpak"],
            "system": ["/usr", "/boot", "/etc"],
        }

        def fs_key(p):
            st = os.statvfs(p)  # same on every btrfs subvolume, unlike f_fsid
            return (st.f_blocks, st.f_frsize)

        try:
            root_key = fs_key("/")
        except OSError:
            root_key = None
        res = {}
        for key, paths in groups.items():
            ex = []
            for p in paths:
                try:  # only count paths that live on the same filesystem as "/"
                    if os.path.isdir(p) and fs_key(p) == root_key:
                        ex.append(p)
                except OSError:
                    pass
            total = 0
            if ex:
                try:
                    r = subprocess.run(["du", "-skx", "--", *ex], capture_output=True,
                                       text=True, timeout=180)
                    for line in r.stdout.splitlines():
                        try:
                            total += int(line.split("\t", 1)[0]) * 1024
                        except ValueError:
                            pass
                except (OSError, subprocess.SubprocessError):
                    pass
            res[key] = total
            if progress:
                progress(dict(res))
        s = sum(res.values())
        if s > used > 0:  # compression / hard links can make du exceed real usage
            res = {k: v * used / s for k, v in res.items()}
            s = used
        res["others"] = max(0, used - s)
        self._bd_cache = (time.time(), res)
        return res

    @staticmethod
    def _make_bar(segs, total, avail_gb):
        ov = Gtk.Overlay()
        ov.set_child(SegBar(segs, total))
        fl = Gtk.Label(label=T("free_gb", n=avail_gb), halign=Gtk.Align.END,
                       valign=Gtk.Align.CENTER, margin_end=10)
        fl.add_css_class("caption")
        fl.set_can_target(False)
        ov.add_overlay(fl)
        return ov

    @staticmethod
    def _make_legend(segs):
        leg = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, column_spacing=14,
                          row_spacing=4, max_children_per_line=6, homogeneous=False)
        for idx, b, lbl in segs:
            item = Gtk.Box(spacing=6)
            dot = Gtk.Label()
            dot.set_markup(f'<span foreground="{SEG_COLORS[idx]}">●</span>')
            tl = Gtk.Label(label=f"{lbl}  {fmt_size(b)}")
            tl.add_css_class("caption")
            item.append(dot)
            item.append(tl)
            leg.append(item)
        return leg

    def _push_storage(self):
        spg = Adw.NavigationPage(title=T("storage"), can_pop=False)
        tv = Adw.ToolbarView()
        tv.add_top_bar(self.nav_header())
        pp = Adw.PreferencesPage()
        gb = 1024 ** 3
        drives, os_name = self._get_drives()

        for name, mp, total, used, avail in drives:
            grp = Adw.PreferencesGroup()
            card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, margin_top=14,
                           margin_bottom=14, margin_start=16, margin_end=16)
            card.add_css_class("card")
            hdr = Gtk.Box()
            nl = Gtk.Label(label=name, xalign=0, hexpand=True)
            nl.add_css_class("heading")
            ul = Gtk.Label(label=T("used_of", used=used / gb, total=total / gb), xalign=1)
            ul.add_css_class("dim-label")
            hdr.append(nl)
            hdr.append(ul)
            card.append(hdr)

            holder = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
            card.append(holder)

            def fill(segs, holder=holder, total=total, avail=avail):
                while (c := holder.get_first_child()):
                    holder.remove(c)
                holder.append(self._make_bar(segs, total, avail / gb))
                holder.append(self._make_legend([s for s in segs if s[1] > 0]))

            if mp == "/":  # real breakdown, computed off the UI thread
                fill([(5, used, T("calculating"))])

                def work(used=used, fill=fill):
                    def mk(bd, final):
                        segs = [
                            (0, bd.get("documents", 0), T("documents")),
                            (1, bd.get("apps", 0), T("apps")),
                            (2, bd.get("media", 0), T("media")),
                            (3, bd.get("system", 0), os_name or T("system")),
                        ]
                        if final:
                            segs.append((4, bd.get("others", 0), T("others")))
                        else:
                            rest = max(0, used - sum(b for _, b, _ in segs))
                            segs.append((5, rest, T("calculating")))
                        return segs
                    try:
                        bd = self._storage_breakdown(used, lambda p: ui(fill, mk(p, False)))
                        ui(fill, mk(bd, True))
                    except Exception:
                        ui(fill, [(5, used, T("used"))])
                threading.Thread(target=work, daemon=True).start()
            else:
                fill([(5, used, T("used"))])

            grp.add(card)
            pp.add(grp)

        g2 = Adw.PreferencesGroup()
        g2.add(self.krow(T("disk_manage"), "disks"))
        pp.add(g2)
        tv.set_content(pp)
        spg.set_child(tv)
        self.cnav.push(spg)

    # ---- Software update ---------------------------------------------------
    def _list_updates(self, kind):
        env = {**os.environ, "LC_ALL": "C"}

        def lines(cmd, ok=(0,)):
            try:
                r = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=120)
            except (OSError, subprocess.SubprocessError):
                return []
            return r.stdout.splitlines() if r.returncode in ok else []

        if kind == "arch":
            if shutil.which("checkupdates"):
                ls = lines(["checkupdates"])
            else:
                ls = []
                for tool in ("paru", "yay", "pacman"):
                    if shutil.which(tool):
                        ls = lines([tool, "-Qu"])
                        break
            return [l.split()[0] for l in ls if l.strip()]
        if kind == "debian":
            return [l.split("/")[0] for l in lines(["apt", "list", "--upgradable"]) if "/" in l]
        if kind == "fedora":
            return [l.split()[0] for l in lines(["dnf", "check-update", "-q"], ok=(0, 100))
                    if len(l.split()) == 3 and "." in l.split()[0]]
        if kind == "suse":
            return [l.split("|")[2].strip() for l in lines(["zypper", "-q", "lu"])
                    if l.startswith("v |") and l.count("|") >= 5]
        if shutil.which("pkcon"):
            return [l.split()[1] for l in lines(["pkcon", "get-updates", "-p"])
                    if l.startswith(("Normal", "Security")) and len(l.split()) > 1]
        return []

    @staticmethod
    def _update_cmd(kind):
        if kind == "arch":
            return ["pkexec", "pacman", "-Syu", "--noconfirm"]
        if kind == "debian":
            return ["pkexec", "bash", "-c",
                    "export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get upgrade -y"]
        if kind == "fedora":
            return ["pkexec", "dnf", "upgrade", "-y"]
        if kind == "suse":
            return ["pkexec", "zypper", "--non-interactive", "up"]
        return ["pkexec", "pkcon", "update", "-y"]

    def _push_update(self):
        kind = self.pm_kind()
        _, _, pretty_os = self.get_os_info()
        up = Adw.NavigationPage(title=T("sw_update"), can_pop=False)
        tv = Adw.ToolbarView()
        tv.add_top_bar(self.nav_header())
        pp = Adw.PreferencesPage()
        sg = Adw.PreferencesGroup(title=esc(pretty_os))
        sr = Adw.ActionRow(title=esc(T("checking_upd")), subtitle=esc(T("please_wait")))
        sp = Gtk.Spinner(spinning=True, valign=Gtk.Align.CENTER)
        sr.add_suffix(sp)
        ub = Gtk.Button(label=T("upd_now"), valign=Gtk.Align.CENTER, visible=False)
        ub.add_css_class("suggested-action")
        sr.add_suffix(ub)
        sg.add(sr)
        pp.add(sg)
        ug_holder = [None]
        tv.set_content(pp)
        up.set_child(tv)
        self.cnav.push(up)

        def show_result(pkgs):
            sp.set_spinning(False)
            sp.set_visible(False)
            if pkgs:
                sr.set_title(esc(T("upd_avail")))
                sr.set_subtitle(esc(T("detected_os", os=pretty_os)))
                ub.set_visible(True)
                ug = Adw.PreferencesGroup(title=esc(T("upd_count", n=len(pkgs))))
                exp = Adw.ExpanderRow(title=esc(T("upd_list_title")))
                for name in pkgs:
                    exp.add_row(Adw.ActionRow(title=esc(name)))
                ug.add(exp)
                pp.add(ug)
                ug_holder[0] = ug
            else:
                sr.set_title(esc(T("up_to_date")))
                sr.set_subtitle(esc(T("no_upd_sub", os=pretty_os)))

        def check():
            ui(show_result, self._list_updates(kind))

        def run_upd(_):
            ub.set_sensitive(False)
            sp.set_visible(True)
            sp.set_spinning(True)
            sr.set_title(esc(T("installing_upd")))
            sr.set_subtitle(esc(T("wait_finish")))

            def worker():
                try:
                    rc = subprocess.run(self._update_cmd(kind)).returncode
                except OSError:
                    rc = 127
                ui(finished, rc)
            threading.Thread(target=worker, daemon=True).start()

        def finished(rc):
            sp.set_spinning(False)
            sp.set_visible(False)
            if rc != 0:  # cancelled auth / failure: let the user retry
                sr.set_title(esc(T("upd_failed")))
                sr.set_subtitle(esc(T("upd_failed_sub")))
                ub.set_sensitive(True)
                return
            ub.set_visible(False)
            if ug_holder[0]:
                pp.remove(ug_holder[0])
                ug_holder[0] = None
            sr.set_title(esc(T("upd_done")))
            sr.set_subtitle(esc(T("reboot_confirm")))
            self.ask_reboot(sr)

        ub.connect("clicked", run_upd)
        threading.Thread(target=check, daemon=True).start()

    def ask_reboot(self, sr):
        secs = AUTO_REBOOT_SEC
        dlg = Adw.MessageDialog(
            transient_for=self.w,
            heading=T("reboot_confirm"),
            body=T("reboot_body", s=secs) if secs > 0 else T("reboot_body_manual"),
        )
        dlg.add_response("later", T("reboot_later"))
        dlg.add_response("now", T("reboot_now"))
        dlg.set_response_appearance("now", Adw.ResponseAppearance.SUGGESTED)
        dlg.set_default_response("later")
        dlg.set_close_response("later")
        state = {"left": secs, "done": False, "auto": False}

        def on_resp(_d, r):
            if state["auto"]:
                return
            state["done"] = True
            if r == "now":
                self.spawn(["systemctl", "reboot"])
            else:
                sr.set_subtitle(esc(T("reboot_postponed")))

        dlg.connect("response", on_resp)

        if secs > 0:
            def tick():
                if state["done"]:
                    return False
                state["left"] -= 1
                if state["left"] <= 0:
                    state["done"] = state["auto"] = True
                    dlg.close()
                    self.spawn(["systemctl", "reboot"])
                    return False
                dlg.set_body(T("reboot_body", s=state["left"]))
                return True
            GLib.timeout_add_seconds(1, tick)
        dlg.present()

    # ---- General / Displays ------------------------------------------------
    def p_gen(self):
        p = Adw.PreferencesPage()
        g = Adw.PreferencesGroup()
        for t, m in [
            (T("about"), "about"),
            (T("date_time"), "clock"),
            (T("lang_region"), "region"),
            (T("sw_update"), "update"),
            (T("storage"), "storage"),
            (T("keyboard"), "keyboard"),
        ]:
            g.add(self.krow(t, m))
        p.add(g)
        return p

    def p_disp(self):
        p = Adw.PreferencesPage()
        g = Adw.PreferencesGroup()
        g.add(self.krow(T("disp_res"), "display"))
        g.add(self.krow(T("night_shift"), "nightlight"))
        p.add(g)
        return p

    # ---- Desktop & Dock ----------------------------------------------------
    def p_desk(self):
        p = Adw.PreferencesPage()
        g = Adw.PreferencesGroup()

        if DE == "kde":
            try:
                factor = float(kread("kdeglobals", "KDE", "AnimationDurationFactor", "1"))
            except ValueError:
                factor = 1.0
            sp = Adw.SpinRow.new_with_range(0, 2, 0.1)
            sp.set_title(esc(T("anim_speed")))
            sp.set_value(factor)

            def on_anim(x, _):
                if self._anim_src:  # debounce: write once after the user stops clicking
                    GLib.source_remove(self._anim_src)
                v = round(x.get_value(), 2)

                def apply():
                    self._anim_src = 0
                    run_seq([kwrite_cmd("kdeglobals", "KDE", "AnimationDurationFactor", v), KWIN_RECONFIGURE])
                    return False
                self._anim_src = GLib.timeout_add(400, apply)

            sp.connect("notify::value", on_anim)
            g.add(sp)
        else:
            asw = Adw.SwitchRow(title=esc(T("anim_enable")))
            asw.set_active(gget("org.gnome.desktop.interface", "enable-animations") != "false")
            asw.connect("notify::active", lambda x, _: run_seq([gset_cmd(
                "org.gnome.desktop.interface", "enable-animations",
                "true" if x.get_active() else "false")]))
            g.add(asw)

        sw = Adw.SwitchRow(title=esc(T("left_buttons")))
        if DE == "kde":
            sw.set_active("X" in kread("kwinrc", "org.kde.kdecoration2", "ButtonsOnLeft"))
        else:
            layout = gget("org.gnome.desktop.wm.preferences", "button-layout")
            sw.set_active("close" in layout.split(":")[0])

        def on_buttons(x, _):
            on = x.get_active()
            if DE == "kde":
                run_seq([
                    kwrite_cmd("kwinrc", "org.kde.kdecoration2", "ButtonsOnLeft", "XIA" if on else "M"),
                    kwrite_cmd("kwinrc", "org.kde.kdecoration2", "ButtonsOnRight", "" if on else "IAX"),
                    KWIN_RECONFIGURE,
                ])
            else:
                run_seq([gset_cmd("org.gnome.desktop.wm.preferences", "button-layout",
                                  "close,minimize,maximize:" if on else ":minimize,maximize,close")])

        sw.connect("notify::active", on_buttons)

        dr = Adw.ActionRow(title=esc(T("dock_settings")),
                           subtitle=esc(T("dock_sub" if DE == "kde" else "dock_sub_gnome")),
                           activatable=True)
        dr.add_suffix(Gtk.Image.new_from_icon_name("go-next-symbolic"))
        dr.connect("activated", lambda _: self.open_dock())

        g.add(sw)
        g.add(dr)
        p.add(g)
        return p

    # ---- Appearance / Wallpaper -------------------------------------------
    def set_scheme(self, dark):
        if DE == "kde":
            run_seq([["plasma-apply-colorscheme", "BreezeDark" if dark else "BreezeLight"]])
        else:
            run_seq([gset_cmd("org.gnome.desktop.interface", "color-scheme",
                              "prefer-dark" if dark else "default")])

    def p_app(self):
        p = Adw.PreferencesPage()
        g = Adw.PreferencesGroup(title=esc(T("app_mode")))
        r = Adw.ActionRow(title=esc(T("color_scheme")))
        b = Gtk.Box(valign=Gtk.Align.CENTER)
        b.add_css_class("linked")
        bl = Gtk.ToggleButton(label=T("light"))
        bd = Gtk.ToggleButton(label=T("dark"), group=bl)
        if DE == "kde":
            is_dark = "dark" in kread("kdeglobals", "General", "ColorScheme").lower()
        else:
            is_dark = "dark" in gget("org.gnome.desktop.interface", "color-scheme")
        (bd if is_dark else bl).set_active(True)
        bl.connect("toggled", lambda x: x.get_active() and self.set_scheme(False))
        bd.connect("toggled", lambda x: x.get_active() and self.set_scheme(True))
        b.append(bl)
        b.append(bd)
        r.add_suffix(b)
        g.add(r)
        g.add(self.krow(T("accent_theme"), "colors"))
        p.add(g)
        return p

    def set_wallpaper(self, f):
        if DE == "kde":
            run_seq([["plasma-apply-wallpaperimage", f.get_path()]])
        else:
            uri, sch = f.get_uri(), "org.gnome.desktop.background"
            run_seq([gset_cmd(sch, "picture-uri", uri), gset_cmd(sch, "picture-uri-dark", uri)])

    def pick_wallpaper(self, _btn):
        dlg = Gtk.FileDialog()
        flt = Gtk.FileFilter()
        flt.set_name(T("images"))
        flt.add_mime_type("image/*")
        store = Gio.ListStore.new(Gtk.FileFilter)
        store.append(flt)
        dlg.set_filters(store)
        dlg.set_default_filter(flt)

        def done(d, res):
            try:
                f = d.open_finish(res)
            except GLib.Error:  # dialog cancelled
                return
            if f and f.get_path():
                self.set_wallpaper(f)

        dlg.open(self.w, None, done)

    def p_wall(self):
        p = Adw.PreferencesPage()
        g = Adw.PreferencesGroup()
        r = Adw.ActionRow(title=esc(T("desk_wall")))
        b = Gtk.Button(label=T("choose_img"), valign=Gtk.Align.CENTER)
        b.add_css_class("suggested-action")
        b.connect("clicked", self.pick_wallpaper)
        r.add_suffix(b)
        g.add(r)
        p.add(g)
        return p


if __name__ == "__main__":
    App().run(None)
PYEOF

python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$TMP/app" \
    || { echo "ERROR: generated script has a syntax error." >&2; exit 1; }

cat > "$TMP/desktop" << 'DESKEOF'
[Desktop Entry]
Name=System Settings
Name[ja]=システム設定
Comment=macOS-style System Settings for KDE Plasma and GNOME
Comment[ja]=KDE Plasma / GNOME 向け macOS 風システム設定
Exec=/usr/local/bin/mac-kde-settings
Icon=preferences-system
Terminal=false
Type=Application
StartupNotify=true
Keywords=settings;system;preferences;設定;
Categories=Settings;System;
DESKEOF

sudo install -Dm755 "$TMP/app" "$BIN"
sudo install -Dm644 "$TMP/desktop" "$DESKTOP"
refresh_desktop_db

echo "Done! Installed to $BIN"
echo "Uninstall with: ./install.sh --uninstall"
