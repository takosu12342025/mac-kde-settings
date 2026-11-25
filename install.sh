#!/usr/bin/env bash
set -e

echo "Installing mac-kde-settings..."

sudo tee /usr/local/bin/mac-kde-settings > /dev/null << 'PYEOF'
#!/usr/bin/env python3
import subprocess, gi, pwd, os, threading, shutil, locale, json

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw, GLib


def detect_ja():
    for k in ("LC_ALL", "LC_MESSAGES", "LANGUAGE", "LANG"):
        v = os.environ.get(k, "")
        if v:
            return v.lower().startswith("ja")
    try:
        loc = locale.getlocale()[0] or ""
        return loc.lower().startswith("ja")
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
    "reboot_confirm": ("再起動しますか？", "Restart Required"),
    "reboot_body": (
        "アップデートを完了するため、{s}秒後に自動的に再起動します。",
        "Your computer will restart automatically in {s} seconds to complete the update.",
    ),
    "reboot_later": ("後で再起動する", "Restart Later"),
    "reboot_now": ("今すぐ再起動", "Restart Now"),
    "reboot_postponed": ("再起動は延期されました", "Restart postponed"),
    "used_of": ("{used:.2f} GB of {total:.2f} GB used", "{used:.2f} GB of {total:.2f} GB used"),
    "documents": ("Documents", "Documents"),
    "apps": ("Apps", "Apps"),
    "media": ("Media", "Media"),
    "others": ("Others", "Others"),
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
}


def T(key, **kw):
    pair = STR.get(key, (key, key))
    s = pair[0] if IS_JA else pair[1]
    return s.format(**kw) if kw else s


def esc(text):
    return GLib.markup_escape_text(str(text))


GLib.set_application_name(T("app_title"))


class App(Adw.Application):
    def __init__(self):
        super().__init__(application_id="com.local.KdeSet")

    def do_activate(self):
        self.w = Adw.ApplicationWindow(
            application=self, default_width=820, default_height=560, title=T("app_title")
        )
        sv = Adw.NavigationSplitView()
        self.w.set_content(sv)
        self.st = Gtk.Stack(transition_type=1)

        items = [
            ("wifi", T("wifi"), "network-wireless-symbolic", self.p_wifi()),
            ("bt", T("bt"), "bluetooth-symbolic", self.p_bt()),
            ("net", T("net"), "network-wired-symbolic", self.p_net()),
            ("bat", T("bat"), "battery-good-symbolic", self.p_bat()),
            ("gen", T("gen"), "preferences-system-symbolic", self.p_gen()),
            ("disp", T("disp"), "video-display-symbolic", self.p_disp()),
            ("desk", T("desk"), "user-desktop-symbolic", self.p_desk()),
            ("app", T("app"), "preferences-desktop-theme-symbolic", self.p_app()),
            ("wall", T("wall"), "preferences-desktop-wallpaper-symbolic", self.p_wall()),
        ]

        sp = Adw.NavigationPage(title=T("app_title"))
        stv = Adw.ToolbarView()
        stv.add_top_bar(Adw.HeaderBar())
        sc = Gtk.ScrolledWindow()
        sc.set_policy(2, 1)
        self.sl = Gtk.ListBox(selection_mode=1)
        self.sl.add_css_class("navigation-sidebar")
        self.sl.connect("row-selected", self.on_sel)

        pw = pwd.getpwuid(os.getuid())
        uname = (pw.pw_gecos.split(",")[0] if pw.pw_gecos else "") or pw.pw_name
        ur = Gtk.ListBoxRow()
        ur.kcm = "kcm_users"
        ub = Gtk.Box(spacing=12, margin_top=6, margin_bottom=6)
        av = Adw.Avatar(size=38, text=uname, show_initials=True)
        face = pw.pw_dir + "/.face.icon"
        if os.path.exists(face):
            av.set_custom_image(Gtk.Image.new_from_file(face).get_paintable())
        utb = Gtk.Box(orientation=1, valign=3)
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
        sel_r = None
        for pid, t, ic, pg in items:
            self.st.add_named(pg, pid)
            r = Gtk.ListBoxRow()
            r.pid = pid
            r.pt = t
            b = Gtk.Box(spacing=12)
            b.append(Gtk.Image.new_from_icon_name(ic))
            b.append(Gtk.Label(label=t, xalign=0))
            r.set_child(b)
            self.sl.append(r)
            self.row_map[pid] = r
            if pid == "gen":
                sel_r = r

        sc.set_child(self.sl)
        stv.set_content(sc)
        sp.set_child(stv)
        sv.set_sidebar(sp)

        self.cnav = Adw.NavigationView()
        cp = Adw.NavigationPage(title=T("gen"))
        ctv = Adw.ToolbarView()
        ctv.add_top_bar(Adw.HeaderBar())
        ctv.set_content(self.st)
        cp.set_child(ctv)
        self.cp = cp
        self.cnav.push(cp)
        sv.set_content(Adw.NavigationPage(title=T("gen"), child=self.cnav))

        if sel_r:
            self.sl.select_row(sel_r)
        self.w.present()

    def on_sel(self, lb, r):
        if not r:
            return
        if hasattr(r, "kcm"):
            subprocess.Popen(["kcmshell6", r.kcm])
            cur = self.st.get_visible_child_name()
            if cur in self.row_map:
                lb.select_row(self.row_map[cur])
        elif hasattr(r, "pid"):
            while self.cnav.get_visible_page() != self.cp:
                self.cnav.pop()
            if r.pid == "net":
                self.refresh_net()
            self.st.set_visible_child_name(r.pid)
            self.cp.set_title(r.pt)

    def krow(self, t, m, s=""):
        r = Adw.ActionRow(title=esc(t), subtitle=esc(s) if s else "", activatable=True)
        r.add_suffix(Gtk.Image.new_from_icon_name("go-next-symbolic"))
        if m == "update":
            r.connect("activated", lambda _: self.open_upd())
        elif m == "storage":
            r.connect("activated", lambda _: self.open_storage())
        else:
            r.connect("activated", lambda _: subprocess.Popen(["kcmshell6", m]))
        return r

    def get_os_info(self):
        d = {}
        if os.path.exists("/etc/os-release"):
            for l in open("/etc/os-release"):
                if "=" in l:
                    k, v = l.strip().split("=", 1)
                    d[k] = v.strip("\"'")
        oid = d.get("ID", "linux").lower()
        like = d.get("ID_LIKE", "").lower()
        pretty = d.get("PRETTY_NAME") or d.get("NAME") or "Linux"
        return oid, like, pretty

    def p_net(self):
        p = Adw.PreferencesPage()
        self.net_grp = Adw.PreferencesGroup()
        p.add(self.net_grp)
        self.net_rows = []

        g2 = Adw.PreferencesGroup()
        g2.add(self.krow(T("wired_vpn"), "kcm_networkmanagement"))
        p.add(g2)
        self.refresh_net()
        return p

    def _badge_icon(self, icon_name, bg_hex):
        box = Gtk.Box(valign=3)
        box.set_size_request(36, 36)
        css = Gtk.CssProvider()
        css.load_from_data(
            f"box {{ background-color: {bg_hex}; border-radius: 8px; padding: 6px; }}".encode()
        )
        box.get_style_context().add_provider(css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        img = Gtk.Image.new_from_icon_name(icon_name)
        img.set_pixel_size(20)
        img.set_hexpand(True)
        img.set_halign(Gtk.Align.CENTER)
        css_i = Gtk.CssProvider()
        css_i.load_from_data(b"image { color: #ffffff; }")
        img.get_style_context().add_provider(css_i, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        box.append(img)
        return box

    def _detect_net_states(self):
        eth_present, eth_up = False, False
        wifi_present, wifi_up = False, False
        try:
            out = subprocess.check_output(["nmcli", "-t", "-f", "TYPE,STATE", "device"], text=True, stderr=subprocess.DEVNULL)
            for line in out.splitlines():
                parts = line.split(":")
                if len(parts) >= 2:
                    dtype, state = parts[0].strip(), parts[1].strip().lower()
                    if dtype == "ethernet":
                        eth_present = True
                        if state.startswith("connected"):
                            eth_up = True
                    elif dtype == "wifi":
                        wifi_present = True
                        if state.startswith("connected"):
                            wifi_up = True
        except Exception:
            pass

        if not eth_present and not wifi_present and os.path.isdir("/sys/class/net"):
            for iface in os.listdir("/sys/class/net"):
                if iface == "lo":
                    continue
                p_oper = f"/sys/class/net/{iface}/operstate"
                is_up = os.path.exists(p_oper) and open(p_oper).read().strip() == "up"
                if os.path.isdir(f"/sys/class/net/{iface}/wireless"):
                    wifi_present = True
                    wifi_up = wifi_up or is_up
                else:
                    eth_present = True
                    eth_up = eth_up or is_up

        fw_up = False
        for svc in ("ufw", "firewalld", "nftables", "iptables"):
            try:
                r = subprocess.run(["systemctl", "is-active", svc], capture_output=True, text=True)
                if r.stdout.strip() == "active":
                    fw_up = True
                    break
            except Exception:
                pass
        if not fw_up and os.path.exists("/etc/ufw/ufw.conf"):
            try:
                if "ENABLED=yes" in open("/etc/ufw/ufw.conf").read():
                    fw_up = True
            except Exception:
                pass

        return eth_present, eth_up, wifi_present, wifi_up, fw_up

    def refresh_net(self):
        for r in self.net_rows:
            self.net_grp.remove(r)
        self.net_rows.clear()

        eth_p, eth_up, wifi_p, wifi_up, fw_up = self._detect_net_states()

        def make_status_row(title, icon_name, bg_color, is_on, on_text, off_text, cb):
            dot_color = "#2ec27e" if is_on else "#9a9996"
            st_text = esc(on_text if is_on else off_text)
            sub = f'<span foreground="{dot_color}">●</span> {st_text}'
            r = Adw.ActionRow(title=esc(title), subtitle=sub, use_markup=True, activatable=True)
            r.add_prefix(self._badge_icon(icon_name, bg_color))
            r.add_suffix(Gtk.Image.new_from_icon_name("go-next-symbolic"))
            r.connect("activated", cb)
            self.net_grp.add(r)
            self.net_rows.append(r)

        if eth_p or not wifi_p:
            make_status_row(
                "Ethernet",
                "network-wired-symbolic",
                "#1c71d8",
                eth_up,
                T("connected"),
                T("cable_unplugged"),
                lambda _: subprocess.Popen(["kcmshell6", "kcm_networkmanagement"]),
            )
        if wifi_p:
            make_status_row(
                T("wifi"),
                "network-wireless-symbolic",
                "#1c71d8",
                wifi_up,
                T("connected"),
                T("disconnected"),
                lambda _: self.sl.select_row(self.row_map["wifi"]),
            )

        make_status_row(
            T("firewall"),
            "security-high-symbolic",
            "#e66100",
            fw_up,
            T("fw_active"),
            T("fw_inactive"),
            lambda _: subprocess.Popen(["kcmshell6", "kcm_firewall"]),
        )

    def _get_drives(self):
        _, _, pretty_os = self.get_os_info()
        drives = []
        try:
            out = subprocess.check_output(
                ["lsblk", "-J", "-b", "-o", "NAME,LABEL,MODEL,MOUNTPOINT,SIZE,TYPE"],
                text=True,
                stderr=subprocess.DEVNULL,
            )
            data = json.loads(out)

            def walk(devs, parent_model=""):
                for d in devs:
                    model = (d.get("model") or parent_model or "").strip()
                    mp = d.get("mountpoint") or ""
                    label = (d.get("label") or "").strip()
                    if mp and (mp == "/" or mp.startswith(("/media/", "/run/media/", "/mnt/"))):
                        st = os.statvfs(mp)
                        total = st.f_blocks * st.f_frsize
                        avail = st.f_bavail * st.f_frsize
                        used = max(0, total - avail)
                        name = label or model or ("System Disk" if mp == "/" else os.path.basename(mp))
                        drives.append((name, mp, total, used, avail, pretty_os))
                    if "children" in d:
                        walk(d["children"], model)

            walk(data.get("blockdevices", []))
        except Exception:
            pass

        if not drives:
            st = os.statvfs("/")
            total = st.f_blocks * st.f_frsize
            avail = st.f_bavail * st.f_frsize
            used = max(0, total - avail)
            drives.append(("System Disk", "/", total, used, avail, pretty_os))
        return drives

    def open_storage(self):
        spg = Adw.NavigationPage(title=T("storage"))
        tv = Adw.ToolbarView()
        tv.add_top_bar(Adw.HeaderBar())
        pp = Adw.PreferencesPage()

        for name, mp, total, used, avail, os_name in self._get_drives():
            gb = 1024 ** 3
            tot_g = total / gb
            used_g = used / gb
            avail_g = avail / gb

            grp = Adw.PreferencesGroup()
            card = Gtk.Box(orientation=1, spacing=12, margin_top=14, margin_bottom=14, margin_start=16, margin_end=16)
            card.add_css_class("card")

            hdr = Gtk.Box()
            nl = Gtk.Label(label=name, xalign=0, hexpand=True)
            nl.add_css_class("heading")
            ul = Gtk.Label(label=T("used_of", used=used_g, total=tot_g), xalign=1)
            ul.add_css_class("dim-label")
            hdr.append(nl)
            hdr.append(ul)
            card.append(hdr)

            ov = Gtk.Overlay()
            bar = Gtk.Box(spacing=1)
            bar.set_size_request(-1, 24)
            bar.set_overflow(Gtk.Overflow.HIDDEN)
            css_b = Gtk.CssProvider()
            css_b.load_from_data(b"box { border-radius: 6px; background-color: rgba(128,128,128,0.25); }")
            bar.get_style_context().add_provider(css_b, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

            used_ratio = min(0.92, max(0.05, used / total)) if total > 0 else 0.1
            segs = [
                ("#e01b24", used_ratio * 0.30, T("documents")),
                ("#ff7800", used_ratio * 0.28, T("apps")),
                ("#f6d32d", used_ratio * 0.16, T("media")),
                ("#33d17a", used_ratio * 0.14, T("others")),
                ("#77767b", used_ratio * 0.12, os_name),
            ]
            for col, ratio, _ in segs:
                seg = Gtk.Box()
                seg.set_size_request(max(4, int(520 * ratio)), 24)
                cs = Gtk.CssProvider()
                cs.load_from_data(f"box {{ background-color: {col}; }}".encode())
                seg.get_style_context().add_provider(cs, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
                bar.append(seg)

            ov.set_child(bar)
            fl = Gtk.Label(label=f"{avail_g:.2f} GB", halign=Gtk.Align.END, valign=Gtk.Align.CENTER, margin_end=10)
            fl.add_css_class("caption")
            ov.add_overlay(fl)
            card.append(ov)

            leg = Gtk.Box(spacing=16)
            for col, _, lbl in segs:
                item = Gtk.Box(spacing=6)
                dot = Gtk.Label()
                dot.set_markup(f'<span foreground="{col}">●</span>')
                tl = Gtk.Label(label=lbl)
                tl.add_css_class("caption")
                item.append(dot)
                item.append(tl)
                leg.append(item)
            card.append(leg)

            grp.add(card)
            pp.add(grp)

        g2 = Adw.PreferencesGroup()
        g2.add(self.krow(T("disk_manage"), "kcm_device_automounter"))
        pp.add(g2)

        tv.set_content(pp)
        spg.set_child(tv)
        self.cnav.push(spg)

    def open_upd(self):
        oid, like, pretty_os = self.get_os_info()
        up = Adw.NavigationPage(title=T("sw_update"))
        tv = Adw.ToolbarView()
        tv.add_top_bar(Adw.HeaderBar())
        pp = Adw.PreferencesPage()
        sg = Adw.PreferencesGroup(title=esc(pretty_os))
        sr = Adw.ActionRow(title=esc(T("checking_upd")), subtitle=esc(T("please_wait")))
        sp = Gtk.Spinner(spinning=True, valign=3)
        sr.add_suffix(sp)
        ub = Gtk.Button(label=T("upd_now"), valign=3, visible=False)
        ub.add_css_class("suggested-action")
        sr.add_suffix(ub)
        sg.add(sr)
        pp.add(sg)
        ug_holder = [None]
        tv.set_content(pp)
        up.set_child(tv)
        self.cnav.push(up)

        def chk():
            pkgs = []
            try:
                if shutil.which("checkupdates"):
                    p = subprocess.run(["checkupdates"], capture_output=True, text=True)
                    pkgs = [l.split()[0] for l in p.stdout.splitlines() if l.strip()]
                elif oid in ["arch", "manjaro", "endeavouros", "cachyos", "garuda"] or "arch" in like:
                    for tool in ("yay", "paru", "pacman"):
                        if shutil.which(tool):
                            p = subprocess.run([tool, "-Qu"], capture_output=True, text=True)
                            pkgs = [l.split()[0] for l in p.stdout.splitlines() if l.strip()]
                            break
                elif oid in ["ubuntu", "debian", "linuxmint", "pop"] or "debian" in like:
                    o = subprocess.check_output(["apt", "list", "--upgradable"], text=True, stderr=subprocess.DEVNULL)
                    pkgs = [l.split("/")[0] for l in o.splitlines()[1:] if "/" in l]
                elif oid in ["fedora", "rhel", "centos", "rocky", "almalinux"] or "fedora" in like:
                    p = subprocess.run(["dnf", "check-update", "-q"], capture_output=True, text=True)
                    pkgs = [l.split()[0] for l in p.stdout.splitlines() if l.strip() and not l.startswith("Obsoleting")]
                elif shutil.which("pkcon"):
                    o = subprocess.check_output(["pkcon", "get-updates", "-p"], text=True, stderr=subprocess.DEVNULL)
                    pkgs = [l.split()[1] for l in o.splitlines() if l.startswith(("Normal", "Security"))]
            except Exception:
                pass

            def ui_done():
                sp.set_spinning(False)
                sp.set_visible(False)
                if len(pkgs) >= 1:
                    sr.set_title(esc(T("upd_avail")))
                    sr.set_subtitle(esc(T("detected_os", os=pretty_os)))
                    ub.set_visible(True)
                    ug = Adw.PreferencesGroup(title=esc(T("upd_count", n=len(pkgs))))
                    ur = Adw.ActionRow(title=esc(T("upd_list_title")), subtitle=esc(chr(10).join(pkgs)))
                    ur.set_subtitle_lines(0)
                    ug.add(ur)
                    pp.add(ug)
                    ug_holder[0] = ug
                else:
                    sr.set_title(esc(T("up_to_date")))
                    sr.set_subtitle(esc(T("no_upd_sub", os=pretty_os)))

            GLib.idle_add(ui_done)

        def run_upd(_):
            ub.set_sensitive(False)
            sp.set_visible(True)
            sp.set_spinning(True)
            sr.set_title(esc(T("installing_upd")))
            sr.set_subtitle(esc(T("wait_finish")))

            def worker():
                if oid in ["arch", "manjaro", "endeavouros", "cachyos", "garuda"] or "arch" in like:
                    cmd = ["pkexec", "pacman", "-Syu", "--noconfirm"]
                elif oid in ["ubuntu", "debian", "linuxmint", "pop"] or "debian" in like:
                    cmd = ["pkexec", "bash", "-c", "apt update && apt upgrade -y"]
                elif oid in ["fedora", "rhel", "centos", "rocky", "almalinux"] or "fedora" in like:
                    cmd = ["pkexec", "dnf", "upgrade", "-y"]
                elif "suse" in oid or "suse" in like:
                    cmd = ["pkexec", "zypper", "up", "-y"]
                else:
                    cmd = ["pkexec", "pkcon", "update", "-y"]
                subprocess.run(cmd)
                GLib.idle_add(upd_finished)

            threading.Thread(target=worker, daemon=True).start()

        def upd_finished():
            sp.set_spinning(False)
            sp.set_visible(False)
            ub.set_visible(False)
            if ug_holder[0]:
                pp.remove(ug_holder[0])
            sr.set_title(esc(T("upd_done")))
            sr.set_subtitle(esc(T("reboot_confirm")))
            sec = [10]
            done = [False]
            dlg = Adw.MessageDialog(
                transient_for=self.w,
                heading=T("reboot_confirm"),
                body=T("reboot_body", s=sec[0]),
            )
            dlg.add_response("later", T("reboot_later"))
            dlg.add_response("now", T("reboot_now"))
            dlg.set_response_appearance("now", Adw.ResponseAppearance.SUGGESTED)

            def on_resp(d, r):
                done[0] = True
                if r == "now":
                    subprocess.Popen(["systemctl", "reboot"])
                else:
                    sr.set_subtitle(esc(T("reboot_postponed")))

            dlg.connect("response", on_resp)

            def tick():
                if done[0]:
                    return False
                sec[0] -= 1
                if sec[0] <= 0:
                    done[0] = True
                    dlg.close()
                    subprocess.Popen(["systemctl", "reboot"])
                    return False
                dlg.set_body(T("reboot_body", s=sec[0]))
                return True

            GLib.timeout_add_seconds(1, tick)
            dlg.present()

        ub.connect("clicked", run_upd)
        threading.Thread(target=chk, daemon=True).start()

    def p_wifi(self):
        p = Adw.PreferencesPage()
        g = Adw.PreferencesGroup()
        s = Adw.SwitchRow(title=esc(T("wifi")), active=True)
        s.connect("notify::active", lambda x, _: subprocess.run(["nmcli", "radio", "wifi", "on" if x.get_active() else "off"]))
        g.add(s)
        g.add(self.krow(T("wired_vpn"), "kcm_networkmanagement"))
        p.add(g)
        return p

    def p_bt(self):
        p = Adw.PreferencesPage()
        g = Adw.PreferencesGroup()
        s = Adw.SwitchRow(title=esc(T("bt")), active=True)
        s.connect("notify::active", lambda x, _: subprocess.run(["bluetoothctl", "power", "on" if x.get_active() else "off"]))
        g.add(s)
        g.add(self.krow(T("bt_devices"), "kcm_bluetooth"))
        p.add(g)
        return p

    def p_bat(self):
        p = Adw.PreferencesPage()
        g = Adw.PreferencesGroup()
        r = Adw.ActionRow(title=esc(T("power_profile")))
        b = Gtk.Box(valign=3)
        b.add_css_class("linked")
        b1 = Gtk.ToggleButton(label=T("low_power"))
        b2 = Gtk.ToggleButton(label=T("auto_power"), group=b1, active=True)
        b3 = Gtk.ToggleButton(label=T("high_power"), group=b1)
        for x, m in [(b1, "power-saver"), (b2, "balanced"), (b3, "performance")]:
            x.connect("toggled", lambda t, mode=m: t.get_active() and subprocess.run(["powerprofilesctl", "set", mode]))
            b.append(x)
        r.add_suffix(b)
        g.add(r)
        p.add(g)
        return p

    def p_gen(self):
        p = Adw.PreferencesPage()
        g = Adw.PreferencesGroup()
        gen_items = [
            (T("about"), "kcm_about-distro"),
            (T("date_time"), "kcm_clock"),
            (T("lang_region"), "kcm_regionandlang"),
            (T("sw_update"), "update"),
            (T("storage"), "storage"),
            (T("keyboard"), "kcm_keyboard"),
        ]
        for t, m in gen_items:
            g.add(self.krow(t, m))
        p.add(g)
        return p

    def p_disp(self):
        p = Adw.PreferencesPage()
        g = Adw.PreferencesGroup()
        g.add(self.krow(T("disp_res"), "kcm_kscreen"))
        g.add(self.krow(T("night_shift"), "kcm_nightlight"))
        p.add(g)
        return p

    def p_desk(self):
        p = Adw.PreferencesPage()
        g = Adw.PreferencesGroup()
        sp = Adw.SpinRow.new_with_range(0, 2, 0.1)
        sp.set_title(esc(T("anim_speed")))
        sp.set_value(1.0)
        sp.connect(
            "notify::value",
            lambda x, _: (
                subprocess.run(["kwriteconfig6", "--file", "kdeglobals", "--group", "KDE", "--key", "AnimationDurationFactor", str(round(x.get_value(), 2))]),
                subprocess.run(["qdbus6", "org.kde.KWin", "/KWin", "reconfigure"]),
            ),
        )
        sw = Adw.SwitchRow(title=esc(T("left_buttons")))
        sw.connect(
            "notify::active",
            lambda x, _: (
                subprocess.run(["kwriteconfig6", "--file", "kwinrc", "--group", "org.kde.kdecoration2", "--key", "ButtonsOnLeft", "XIA" if x.get_active() else "M"]),
                subprocess.run(["kwriteconfig6", "--file", "kwinrc", "--group", "org.kde.kdecoration2", "--key", "ButtonsOnRight", "" if x.get_active() else "IAX"]),
                subprocess.run(["qdbus6", "org.kde.KWin", "/KWin", "reconfigure"]),
            ),
        )
        dr = Adw.ActionRow(title=esc(T("dock_settings")), subtitle=esc(T("dock_sub")), activatable=True)
        dr.add_suffix(Gtk.Image.new_from_icon_name("go-next-symbolic"))
        dr.connect(
            "activated",
            lambda _: subprocess.Popen([
                "qdbus6", "org.kde.plasmashell", "/PlasmaShell",
                "org.freedesktop.DBus.Properties.Set", "org.kde.PlasmaShell", "editMode", "true"
            ]),
        )
        g.add(sp)
        g.add(sw)
        g.add(dr)
        p.add(g)
        return p

    def p_app(self):
        p = Adw.PreferencesPage()
        g = Adw.PreferencesGroup(title=esc(T("app_mode")))
        r = Adw.ActionRow(title=esc(T("color_scheme")))
        b = Gtk.Box(valign=3)
        b.add_css_class("linked")
        bl = Gtk.ToggleButton(label=T("light"))
        bd = Gtk.ToggleButton(label=T("dark"), group=bl, active=True)
        bl.connect("toggled", lambda x: x.get_active() and subprocess.run(["plasma-apply-colorscheme", "BreezeLight"]))
        bd.connect("toggled", lambda x: x.get_active() and subprocess.run(["plasma-apply-colorscheme", "BreezeDark"]))
        b.append(bl)
        b.append(bd)
        r.add_suffix(b)
        g.add(r)
        g.add(self.krow(T("accent_theme"), "kcm_colors"))
        p.add(g)
        return p

    def p_wall(self):
        p = Adw.PreferencesPage()
        g = Adw.PreferencesGroup()
        r = Adw.ActionRow(title=esc(T("desk_wall")))
        b = Gtk.Button(label=T("choose_img"), valign=3)
        b.add_css_class("suggested-action")
        b.connect(
            "clicked",
            lambda _: Gtk.FileDialog().open(
                self.get_active_window(),
                None,
                lambda d, res: subprocess.run(["plasma-apply-wallpaperimage", d.open_finish(res).get_path()]),
            ),
        )
        r.add_suffix(b)
        g.add(r)
        p.add(g)
        return p


if __name__ == "__main__":
    App().run(None)
PYEOF

sudo chmod +x /usr/local/bin/mac-kde-settings

sudo tee /usr/share/applications/mac-kde-settings.desktop > /dev/null << 'DESKEOF'
[Desktop Entry]
Name=System Settings
Name[ja]=システム設定
Comment=macOS-style System Settings for KDE Plasma
Exec=/usr/local/bin/mac-kde-settings
Icon=preferences-system
Terminal=false
Type=Application
Categories=Settings;System;
DESKEOF

echo "Done! Installed to /usr/local/bin/mac-kde-settings"
