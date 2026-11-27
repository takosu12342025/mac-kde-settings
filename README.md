[🇯🇵日本語](README.jp.md)
# mac-kde-settings
This is a KDE configuration based on GTK4 that features a macOS-like appearance. The application is built using GTK4 and Python,\ and it pays homage to the macOS user interface (UI) style.
# images
![settings-en-d](./images/darken.png)
![settings-en-l](./images/lighten.png)

(I am using the [macos-tahoe-liquid-kde](https://github.com/lestercorderomurillo/macos-tahoe-liquid-kde) theme.)

# Installation
Dependency packages\
pacman
```bash
sudo pacman -S python-gobject gtk4 libadwaita
```
apt
```bash
sudo apt install python3-gi gir1.2-gtk-4.0 gir1.2-adw-1
```
dnf
```bash
sudo dnf install python3-gobject gtk4 libadwaita
```
Installation procedure
```bash
git clone https://github.com/takosu12342025/mac-kde-settings
cd mac-kde-settings
bash install.sh
```
# Uninstallation
```bash
cd mac-kde-settings
bash install.sh --uninstall
```

# Dependencies
Required runtime and UI libraries (the application will not launch without these):\

• Python 3 (python / python3)\
• PyGObject (python-gobject / python3-gi) — A bridge for using GTK with Python\
• GTK 4 (gtk4 / libgtk-4-1)\
• Libadwaita (libadwaita / libadwaita-1-0) — A library used for rendering macOS-style elements, such as sidebars, rounded-corner cards, and dialogs
# Note
This app was created using AI.\
It was translated using Google Translate.\

# GNOME-KDE
The new version now supports GNOME!\
If it doesn't work, please run the following:
```bash
sudo python3 -c '
p = "/usr/local/bin/mac-kde-settings"
with open(p, "r") as f:
    s = f.read()
old = "info = Gio.DesktopAppInfo.new(fmt.format(name))"
new = """try:
                    info = Gio.DesktopAppInfo.new(fmt.format(name))
                except TypeError:
                    info = None"""
assert old in s, "Could not find the target section"
with open(p, "w") as f:
    f.write(s.replace(old, new, 1))
print("Fix applied successfully!")
'
```
