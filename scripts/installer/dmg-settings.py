# dmgbuild settings for Kagami's disk image. scripts/make-installers.sh passes the paths with -D.
# The window is exactly the background (660 × 420 pt); Finder draws the two icons on the bronze arc's ends.
app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["volume_icon"]
background = defines["background"]

format = "ULFO"          # LZFSE: smaller and faster to open than zlib
filesystem = "HFS+"
size = None

window_rect = ((200, 140), (660, 420))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False

arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 13
icon_size = 128
icon_locations = {
    "Kagami.app": (170, 205),
    "Applications": (490, 205),
}
hide_extension = ["Kagami.app"]
