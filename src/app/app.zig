//! The Renux window: sessions and their windows in a sidebar, the chosen window's panes on the
//! right, and a connect page until a server is set.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const glib = @import("glib");
const gobject = @import("gobject");
const gio = @import("gio");
const gtk = @import("gtk");
const gdk = @import("gdk");
const graphene = @import("graphene");
const gsk = @import("gsk");
const pango = @import("pango");
const adw = @import("adw");
const server_mod = @import("../rex/server.zig");
const updates = @import("../rex/updates.zig");
const view = @import("../rex/view.zig");
const termview = @import("../terminal/termview.zig");
const programs = @import("../icons/programs.zig");
const Server = server_mod.Server;
const Workspace = @import("../ui/workspace.zig").Workspace;
const settings = @import("../settings/settings.zig");
const themes = @import("../theme/themes.zig");
const theme = @import("../theme/theme.zig");
const icons = @import("../icons/icons.zig");
const keys = @import("../terminal/keys.zig");
const Palette = @import("../ui/palette.zig").Palette;
const prompt_ui = @import("../ui/prompt.zig");
const prompt_json = @import("../util/json.zig");
const reorder = @import("../ui/reorder.zig");
const sidebar_tools = @import("../ui/sidebar_tools.zig");
const sidebar_slide = @import("../ui/sidebar_slide.zig");
const wayland = @import("../platform/wayland.zig");

const gpa = std.heap.c_allocator;

/// The window's corner radius while see-through, which the Mac's frosted glass matches.
const window_radius = 12;

const css =
    \\window.renux, window.renux .sidebar-pane { background-color: @renux_shell; }
    \\*, *:focus-visible, *:focus-within { outline: none; outline-width: 0; }
    \\.close-session-confirmation button:focus { outline: 2px solid @window_fg_color; outline-offset: -3px; }
    \\.carry-ghost { background-color: mix(@view_bg_color, @window_fg_color, 0.1); border: 1.5px solid alpha(@accent_bg_color, 0.9); border-radius: 10px; box-shadow: 0 5px 18px alpha(black, 0.35); }
    \\.font-preview { padding: 12px 14px; }
    \\.hover-card > contents { padding: 12px 14px; border-radius: 13px; min-width: 250px; }
    \\.hover-title { font-weight: 700; }
    \\.hover-name { font-weight: 500; }
    \\.hover-dim { color: @renux_secondary; font-size: 0.9em; }
    \\.hover-chip { font-size: 0.8em; font-weight: 600; padding: 1px 8px; border-radius: 7px; background-color: alpha(@window_fg_color, 0.1); color: @renux_secondary; }
    \\.hover-chip.blocked { color: @warning_color; }
    \\.hover-chip.failed { color: @error_color; }
    \\.settings-plain-row { padding: 0; }
    \\.settings-cards { padding: 12px 12px 10px 12px; }
    \\.settings-cards-title { font-size: 0.9em; color: @renux_secondary; margin-left: 4px; }
    \\.pick-card { padding: 5px 5px 7px 5px; border-radius: 13px; font-weight: 400; color: @renux_secondary; transition: box-shadow 140ms ease-out, background-color 140ms ease-out; }
    \\.pick-card:checked { background-color: alpha(@accent_bg_color, 0.12); box-shadow: inset 0 0 0 2px @accent_bg_color; color: @window_fg_color; font-weight: 700; }
    \\.settings-sample-row { padding: 12px; }
    \\.board { background-color: @renux_shell; padding: 14px 14px 12px 14px; }
    \\.panes.under-board { opacity: 0; transition: opacity 200ms ease-in; }
    \\.panes.under-board.at-once { transition: none; }
    \\.board-title { font-weight: 700; font-size: 1.15em; margin-left: 4px; }
    \\.board-column { background-color: @view_bg_color; border-radius: 11px; border: 1px solid @renux_stroke_subtle; padding: 10px 8px 8px 8px; }
    \\.board-column-head { padding: 0 6px 2px 4px; }
    \\.board-column-title { font-weight: 700; }
    \\.board-count { color: @renux_secondary; font-size: 0.9em; }
    \\.agent-row { min-height: 44px; }
    \\.agent-status { font-size: 0.86em; color: @renux_secondary; }
    \\.agent-status.blocked { color: @warning_color; }
    \\.agent-status.failed { color: @error_color; }
    \\.eye-dot { min-width: 7px; min-height: 7px; border-radius: 99px; margin: -2px -3px 0 0; background-color: @accent_bg_color; box-shadow: 0 0 0 1.5px @renux_shell; }
    \\.eye-dot.done { background-color: #3b82f6; }
    \\.eye-dot.blocked { background-color: #f59e0b; }
    \\.eye-dot.failed { background-color: #ef4444; }
    \\.board-session { font-size: 0.82em; font-weight: 600; color: @renux_secondary; margin: 6px 0 -2px 6px; }
    \\.board-session:first-child { margin-top: 0; }
    \\.board-grouping button { min-height: 26px; padding: 0 12px; font-size: 0.88em; }
    \\.board-empty { color: @renux_secondary; font-size: 0.9em; margin-top: 18px; }
    \\.board-card { background-color: mix(@view_bg_color, @window_fg_color, 0.05); border-radius: 10px; padding: 10px 12px; font-weight: 400; box-shadow: inset 0 0 0 1px @renux_stroke_subtle, 0 1px 4px alpha(black, 0.12); transition: background-color 140ms ease-out, box-shadow 140ms ease-out; }
    \\.board-card:hover { background-color: mix(@view_bg_color, @window_fg_color, 0.09); box-shadow: inset 0 0 0 1px alpha(@window_fg_color, 0.22), 0 3px 10px alpha(black, 0.2); }
    \\.board-card.attention { box-shadow: inset 0 0 0 1px alpha(@warning_color, 0.6), 0 1px 4px alpha(black, 0.12); }
    \\.board-card:focus-visible { outline: 2px solid alpha(@accent_bg_color, 0.85); outline-offset: -2px; }
    \\.board-card-title { font-weight: 600; }
    \\.board-card-message { color: @renux_secondary; font-size: 0.92em; }
    \\.board-card-meta { color: @renux_secondary; font-size: 0.82em; }
    \\.board-card-progress { margin: 2px 0; }
    \\.board-card.arrived { animation: board-arrive 320ms cubic-bezier(0.2, 0.9, 0.3, 1.1); }
    \\@keyframes board-arrive { from { opacity: 0; transform: translateY(10px) scale(0.96); } to { opacity: 1; transform: none; } }
    \\.divider-line { border-radius: 99px; background-color: alpha(@accent_bg_color, 0.85); opacity: 0; transition: opacity 140ms ease-out; }
    \\.divider-line.shown { opacity: 1; transition: opacity 90ms ease-out 60ms; }
    \\.drop-target { background-color: alpha(@accent_bg_color, 0.16); border: 1.5px solid alpha(@accent_bg_color, 0.8); border-radius: 9px; color: @accent_color; }
    \\.peek > contents { padding: 12px; border-radius: 16px; animation: peek-in 400ms linear; }
    \\.peek.leaving > contents { animation: peek-out 200ms linear forwards; }
    \\/* Opens the way a new pane's card does: from a little smaller, on the same spring, fading in.
    \\   It closes the same way backwards, less the last stretch of the spring, where nothing can be seen to move. */
    \\@keyframes peek-in { 0% { opacity: 0; transform: scale(0.92); } 12.5% { opacity: 0.5; transform: scale(0.941); } 25% { opacity: 0.75; transform: scale(0.968); } 37.5% { opacity: 0.88; transform: scale(0.984); } 50% { opacity: 0.94; transform: scale(0.993); } 75% { opacity: 0.985; transform: scale(0.999); } 100% { opacity: 1; transform: none; } }
    \\@keyframes peek-out { 0% { opacity: 1; transform: none; } 25% { opacity: 0.88; transform: scale(0.984); } 50% { opacity: 0.75; transform: scale(0.968); } 75% { opacity: 0.5; transform: scale(0.941); } 100% { opacity: 0; transform: scale(0.92); } }
    \\.peek-head { padding: 2px 4px 0 4px; }
    \\.peek-body { background-color: @view_bg_color; border-radius: 10px; }
    \\.peek-rows { padding: 8px 0; }
    \\.peek-row { padding: 2px 16px 2px 2px; }
    \\.peek-row.peek-entry { padding-left: 18px; }
    \\.peek-row.peek-target { background-color: alpha(@accent_bg_color, 0.18); }
    \\.peek-message { padding: 0 18px; }
    \\.peek-path { font-family: monospace; font-size: 0.85em; color: @renux_secondary; padding: 0 18px; }
    \\.peek-arrived { animation: peek-arrived 200ms ease-out; }
    \\@keyframes peek-arrived { from { opacity: 0; } to { opacity: 1; } }
    \\.peek-picture { margin: 10px; }
    \\.peek button { padding: 5px 7px 5px 14px; border-radius: 9px; }
    \\.peek-key { font-family: monospace; font-size: 0.8em; padding: 2px 7px; border-radius: 6px; background-color: alpha(currentColor, 0.14); }
    \\.sidebar-header { min-height: 52px; padding: 0 8px; }
    \\.renux-sidebar list { background: none; padding: 2px 0 8px 8px; }
    \\window.sidebar-end .renux-sidebar list { padding: 2px 8px 8px 0; }
    \\window.tight .renux-sidebar list { padding: 2px 8px 8px 8px; }
    \\.renux-sidebar list > row { border-radius: 8px; min-height: 30px; padding: 0 5px 0 8px; margin: 0 0 3px 0; }
    \\.renux-sidebar list > row:selected { background-color: alpha(@window_fg_color, 0.09); box-shadow: 0 1px 3px alpha(black, 0.14); }
    \\.renux-sidebar list > row { transition: transform 220ms cubic-bezier(0.2, 0.9, 0.3, 1), background-color 120ms ease-out; }
    \\.renux-sidebar list > row.drag-source { opacity: 0; }
    \\scrollbar { opacity: 0; }
    \\.renux-sidebar list > row:focus-visible { outline: 2px solid alpha(@accent_bg_color, 0.85); outline-offset: -2px; background-color: alpha(@window_fg_color, 0.06); }
    \\.renux-sidebar list { transition: opacity 170ms ease-out, transform 220ms cubic-bezier(0.2, 0.9, 0.3, 1); }
    \\.renux-sidebar list.swapping { opacity: 0; transform: translateY(6px); transition: opacity 110ms ease-in, transform 110ms ease-in; }
    \\.session-ghost { border-radius: 10px; background-color: mix(@renux_shell, @window_fg_color, 0.07); box-shadow: 0 0 0 1px @renux_stroke_subtle, 0 8px 22px alpha(black, 0.28); animation: ghost-lift 150ms ease-out; transition: box-shadow 170ms ease-out; }
    \\.session-ghost.landing { box-shadow: 0 0 0 1px @renux_stroke_subtle, 0 1px 3px alpha(black, 0.1); }
    \\@keyframes ghost-lift { from { background-color: alpha(@renux_shell, 0); box-shadow: 0 0 0 1px alpha(black, 0), 0 0 0 alpha(black, 0); } }
    \\window.tight .renux-sidebar list > row:selected { box-shadow: none; }
    \\.renux-sidebar list > row:hover:not(:selected):not(.session-row):not(.host-row) { background-color: alpha(@window_fg_color, 0.04); }
    \\.renux-sidebar .row-title { font-size: 0.95em; }
    \\.row-more { opacity: 0; }
    \\.row-more, .row-more > button { min-height: 20px; min-width: 24px; padding: 0; margin: 0; border-radius: 6px; }
    \\row:hover .row-more, row:selected .row-more { opacity: 0.6; }
    \\.session-heading { font-size: 0.82em; color: @renux_secondary; }
    \\.renux-sidebar list > row.session-row { min-height: 22px; margin-top: 8px; padding: 0 2px 0 8px; background: none; }
    \\.renux-sidebar list > row.host-row { min-height: 22px; margin-top: 12px; padding: 0 8px; background: none; }
    \\.renux-sidebar list > row.host-row:first-child { margin-top: 4px; }
    \\.host-heading { font-weight: 700; font-size: 0.88em; }
    \\.session-tool { opacity: 0; min-width: 22px; min-height: 22px; }
    \\row.session-row:hover .session-tool, .session-tool.folded { opacity: 0.6; }
    \\row.session-row .session-tool:hover { opacity: 1; }
    \\.sidebar-handle { background: none; }
    \\.sidebar-handle:hover { background-image: linear-gradient(to right, transparent 3px, alpha(@accent_bg_color, 0.6) 3px, alpha(@accent_bg_color, 0.6) 5px, transparent 5px); }
    \\.sidebar-footer { padding: 8px 12px 12px 12px; }
    \\.sidebar-footer > * { margin-left: 2px; }
    \\.filter-pill { border-radius: 99px; min-height: 30px; padding: 0 8px; transition: background-color 140ms ease-out, color 140ms ease-out; }
    \\.filter-pill.filtered { background-color: alpha(@accent_bg_color, 0.16); color: @accent_color; box-shadow: inset 0 0 0 1px alpha(@accent_bg_color, 0.35); }
    \\.filter-pill.filtered:hover { background-color: alpha(@accent_bg_color, 0.24); }
    \\.window-card.alone { margin-left: 8px; }
    \\.content .workspace { margin: 8px; }
    \\.content.alone .workspace { margin: 8px; }
    \\window.no-headers .content.alone .workspace { margin-top: 52px; }
    \\window.tight .content.alone .workspace { margin: 0; }
    \\.window-corner { min-height: 52px; padding: 0 6px 0 12px; }
    \\.pane-card { background-color: @view_bg_color; border-radius: 11px; border: 1px solid @renux_stroke_subtle; box-shadow: 0 0 8px alpha(black, 0.16); }
    \\.pane-card.joined { box-shadow: none; }
    \\.pane-card.focused { border-color: alpha(@accent_bg_color, 0.85); box-shadow: 0 0 0 1px alpha(@accent_bg_color, 0.35), 0 0 8px alpha(black, 0.16); }
    \\.pane-card.floating { box-shadow: 0 8px 28px alpha(black, 0.45); }
    \\.pane-card.floating.focused { box-shadow: 0 0 0 1px alpha(@accent_bg_color, 0.35), 0 8px 28px alpha(black, 0.45); }
    \\.layer-card { background-color: @renux_stroke_subtle; border: 1px solid @renux_stroke_subtle; border-radius: 11px; box-shadow: 0 8px 28px alpha(black, 0.45); }
    \\.layer-card.focused { border-color: alpha(@accent_bg_color, 0.85); }
    \\.pane-card.joined.focused .pane-title .title { color: @accent_color; }
    \\.pane-title { min-height: 38px; padding: 0 6px 0 12px; }
    \\.pane-tools > * { margin-left: 2px; }
    \\.pane-title .title { font-weight: 500; font-size: 0.95em; }
    \\.pane-card:not(.focused) .pane-title .title { color: @renux_secondary; }
    \\.pane-tools { opacity: 0; transition: opacity 120ms; }
    \\.pane-card.focused .pane-tools, .pane-card:hover .pane-tools { opacity: 1; }
    \\.icon-button { min-width: 26px; min-height: 26px; padding: 0; border-radius: 7px; opacity: 0.5; }
    \\.icon-button:hover { opacity: 1; background-color: alpha(@window_fg_color, 0.08); }
    \\.icon-button:checked { opacity: 1; background-color: alpha(@window_fg_color, 0.12); }
    \\.find-bar { margin: 6px 12px 14px 12px; padding: 4px 5px 4px 6px; min-width: 230px; border-radius: 13px; background-color: @popover_bg_color; box-shadow: 0 6px 22px alpha(black, 0.32), inset 0 0 0 1px @renux_stroke_subtle; }
    \\.find-bar entry { background: none; box-shadow: none; outline: none; border: none; min-height: 28px; padding-left: 6px; }
    \\.find-count { color: @renux_secondary; font-size: 0.9em; margin: 0 8px 0 4px; }
    \\.tray-chip { border-radius: 9px; padding: 4px 10px 4px 6px; background-color: @popover_bg_color; box-shadow: 0 2px 10px alpha(black, 0.3); }
    \\.tray-chip { transition: background-color 140ms ease-out, box-shadow 140ms ease-out; }
    \\.chip-face { box-shadow: none; }
    \\.tray-chip:hover { background-color: mix(@popover_bg_color, @window_fg_color, 0.1); box-shadow: 0 4px 16px alpha(black, 0.38); }
    \\.tray-chip:active { background-color: mix(@popover_bg_color, @window_fg_color, 0.16); }
    \\.tray-chip.carried { background-color: mix(@popover_bg_color, @window_fg_color, 0.1); box-shadow: 0 0 0 1px @renux_stroke_subtle, 0 8px 22px alpha(black, 0.28); transition: background-color 150ms ease-out, box-shadow 170ms ease-out; }
    \\window.tight .content .workspace { margin: 0; }
    \\window.tight.no-headers .content.alone .workspace { margin-top: 38px; }
    \\window.tight:not(.tabs-above) .window-corner { min-height: 38px; }
    \\window.tight:not(.tabs-above) .sidebar-header { min-height: 38px; }
    \\window.tight .pane-card { border-radius: 0; border: none; box-shadow: none; }
    \\window.tight .workspace { background-color: @renux_stroke_subtle; }
    \\window.tight .pane-card.focused .pane-title .title { color: @accent_color; }
    \\window.tight .pane-card.floating { border: 1px solid @renux_stroke; border-radius: 8px; box-shadow: 0 8px 28px alpha(black, 0.45); }
    \\.pane-card.joined, .pane-card.joined.floating, .pane-card.joined.focused, .pane-card.joined.floating.focused { border: none; box-shadow: none; }
    \\window .pane-card.joined.floating { border-radius: 0; }
    \\window .pane-card.joined.floating.c-tl { border-top-left-radius: 10px; }
    \\window .pane-card.joined.floating.c-tr { border-top-right-radius: 10px; }
    \\window .pane-card.joined.floating.c-bl { border-bottom-left-radius: 10px; }
    \\window .pane-card.joined.floating.c-br { border-bottom-right-radius: 10px; }
    \\.palette { padding: 12px; }
    \\.palette-category { color: @renux_secondary; font-size: 0.85em; }
    \\.palette-keys { font-family: monospace; font-size: 0.85em; color: @renux_secondary; background-color: alpha(@window_fg_color, 0.07); border-radius: 5px; padding: 1px 6px; }
    \\.activity-panel { background-color: @popover_bg_color; border-radius: 12px; box-shadow: 0 10px 34px alpha(black, 0.42), inset 0 0 0 1px alpha(@window_fg_color, 0.08); }
    \\.activity-panel { opacity: 0; transform: translateX(28px); transition: opacity 130ms ease-in, transform 150ms ease-in; }
    \\.activity-panel.shown { opacity: 1; transform: none; transition: opacity 150ms ease-out, transform 240ms cubic-bezier(0.2, 0.9, 0.3, 1); }
    \\.activity-head { padding: 12px 12px 6px 16px; }
    \\.activity-title { font-weight: 700; font-size: 1.05em; }
    \\.activity-head button { min-height: 24px; padding: 0 10px; font-size: 0.85em; }
    \\.activity-idle { margin: 0 0 6px 12px; font-size: 0.9em; color: @renux_secondary; }
    \\.activity-list { background: none; padding: 0 6px 8px 6px; }
    \\.activity-heading { font-size: 0.8em; font-weight: 600; color: @renux_secondary; margin: 10px 0 2px 8px; }
    \\.activity-row { border-radius: 9px; padding: 6px 8px; }
    \\.activity-row:hover { background-color: alpha(@window_fg_color, 0.06); }
    \\.activity-row.current { background-color: alpha(@window_fg_color, 0.09); box-shadow: 0 1px 3px alpha(black, 0.14); }
    \\.activity-row.current:hover { background-color: alpha(@window_fg_color, 0.12); }
    \\.activity-row:focus-visible { outline: 2px solid alpha(@accent_bg_color, 0.85); outline-offset: -2px; background-color: alpha(@window_fg_color, 0.06); }
    \\.activity-when { font-size: 0.8em; color: @renux_secondary; margin-left: 8px; }
    \\.activity-progress { margin: 4px 0 1px 0; }
    \\.activity-hint { font-size: 0.78em; color: alpha(@window_fg_color, 0.45); padding: 7px 0 10px 0; }
    \\.activity-name { font-weight: 500; }
    \\.activity-detail { font-size: 0.85em; color: @renux_secondary; }
    \\.activity-row.blocked .activity-detail { color: @warning_color; }
    \\.activity-row.failed .activity-detail { color: @error_color; }
    \\.activity-unread { min-width: 8px; min-height: 8px; border-radius: 99px; background-color: @accent_bg_color; }
    \\.tab-strip { padding: 0 8px 0 0; min-height: 52px; }
    \\.tab-strip > * { margin-top: 11px; margin-bottom: 5px; }
    \\window.tabs-above .content .workspace { margin-top: 0; }
    \\.content.alone .tab-strip { padding-left: 8px; }
    \\.tab { border-radius: 9px; min-height: 30px; padding: 0 5px 0 10px; color: @renux_secondary; }
    \\.tab:hover { background-color: alpha(@window_fg_color, 0.05); }
    \\.tab.active { background-color: alpha(@window_fg_color, 0.10); color: @window_fg_color; }
    \\.tab .tab-close { opacity: 0; min-width: 20px; min-height: 20px; padding: 0; margin: 0; border-radius: 6px; }
    \\.tab:hover .tab-close, .tab.active .tab-close { opacity: 0.55; }
    \\window.tabs-above .renux-sidebar list > row.session-pick { min-height: 28px; margin-top: 2px; border-radius: 8px; }
    \\window.tabs-above .renux-sidebar list > row.session-pick:selected { background-color: alpha(@window_fg_color, 0.09); }
    \\window.tabs-above .renux-sidebar row.session-pick .session-heading { font-size: 0.95em; color: @window_fg_color; }
    \\window.tight.sidebar-end .content .workspace { margin: 0; }
    \\.goto { padding: 12px; }
    \\.goto-detail { font-size: 0.85em; color: @renux_secondary; }
    \\.goto-path { font-family: monospace; font-size: 0.9em; color: @renux_secondary; margin: 0 4px; }
    \\.goto-kind { font-size: 0.75em; color: @renux_secondary; background-color: alpha(@window_fg_color, 0.07); border-radius: 5px; padding: 1px 7px; }
    \\.goto-row { padding: 6px 8px; }
    \\.record-box { padding: 24px; }
    \\.record-keys { font-family: monospace; font-size: 1.6em; font-weight: 700; color: @accent_color; min-height: 40px; }
    \\.welcome-icon { color: @accent_color; margin-bottom: 6px; }
    \\.diagnostics-text { font-family: monospace; font-size: 0.92em; }
    \\.key-hints { background-color: alpha(@popover_bg_color, 0.96); border-radius: 14px; padding: 12px 16px; box-shadow: 0 8px 30px alpha(black, 0.4), inset 0 0 0 1px alpha(@window_fg_color, 0.08); }
    \\.key-hints, .mode-chip { opacity: 0; transform: translateY(8px); transition: opacity 120ms ease-in, transform 120ms ease-in; }
    \\.key-hints.shown, .mode-chip.shown { opacity: 1; transform: none; transition: opacity 140ms ease-out, transform 200ms cubic-bezier(0.2, 0.9, 0.3, 1); }
    \\.hint-key { font-family: monospace; font-weight: 700; color: @accent_color; min-width: 18px; min-height: 20px; }
    \\.hint-desc { min-height: 20px; }
    \\.mode-chip { background-color: @accent_bg_color; color: @accent_fg_color; font-weight: 700; font-size: 0.85em; border-radius: 99px; padding: 6px 16px; box-shadow: 0 4px 16px alpha(black, 0.35); }
    \\.connect-box { margin: 0 24px; }
    \\.overview-name { font-size: 0.9em; font-weight: 600; color: alpha(@window_fg_color, 0.55); text-shadow: 0 1px 4px alpha(@renux_shell, 0.7); transition: color 140ms ease-out; }
    \\.overview-name.chosen { color: @window_fg_color; }
    \\.overview-dots { background-color: alpha(black, 0.38); border-radius: 99px; padding: 4px 6px; }
    \\.overview-dot { min-width: 7px; min-height: 7px; border-radius: 99px; background-color: alpha(white, 0.32); }
    \\.overview-dot.working { background-color: #5aa9ff; }
    \\.overview-dot.blocked { background-color: #ffa424; }
    \\.overview-dot.failed { background-color: #ff5a52; }
    \\.overview-dot.done { background-color: #4cc76a; }
    \\.overview-host { background-color: alpha(black, 0.38); border-radius: 99px; padding: 1px 9px; font-size: 0.75em; font-weight: 600; color: alpha(white, 0.82); }
    \\.overview-group { background-color: alpha(@window_fg_color, 0.05); border-radius: 14px; box-shadow: inset 0 0 0 1px alpha(@window_fg_color, 0.07); }
    \\.overview-hint { font-size: 0.8em; color: alpha(@window_fg_color, 0.5); text-shadow: 0 1px 3px alpha(@renux_shell, 0.6); }
    \\.overview-blank { background-color: alpha(@view_bg_color, 0.7); border-radius: 6px; box-shadow: inset 0 0 0 1px @renux_stroke_subtle; }
    \\.overview-ring { border: 2px solid @accent_bg_color; border-radius: 8px; }
    \\.overview-button { padding: 4px 16px; font-size: 0.9em; }
    \\window.renux.bare .content .workspace, window.renux.bare .content.alone .workspace { margin: 0; }
    \\window.renux.bare .renux-sidebar { border-radius: 11px; border: 1px solid @renux_stroke_subtle; margin-right: 8px; }
    \\window.renux.bare.sidebar-end .renux-sidebar { margin-right: 0; margin-left: 8px; }
    \\window.renux.bare.tight .renux-sidebar { border-radius: 0; border: none; margin-right: 1px; }
    \\window.renux.bare.tight.sidebar-end .renux-sidebar { margin-right: 0; margin-left: 1px; }
    \\window.renux.bare .overview-name, window.renux.bare .overview-hint { background-color: @popover_bg_color; border-radius: 99px; padding: 2px 10px; text-shadow: none; box-shadow: 0 1px 6px alpha(black, 0.25); }
    \\window.renux.bare .overview-hint { color: alpha(@window_fg_color, 0.7); }
    \\window.renux.bare .overview-session { background-color: @window_fg_color; color: @popover_bg_color; }
    \\window.renux.bare .overview-group { background: none; box-shadow: none; }
    \\window.renux.bare .overview-button { background-color: @popover_bg_color; box-shadow: 0 1px 6px alpha(black, 0.25); }
    \\window.renux.bare .overview-button:hover { background-color: mix(@popover_bg_color, @window_fg_color, 0.1); }
    \\window.renux.bare .overview-button:checked { background-color: mix(@popover_bg_color, @window_fg_color, 0.16); }
;

const Row = struct { host: *Host, session_id: []u8, window_id: []u8, block_id: []u8 = &.{}, label: ?*gtk.Label = null, line: ?*gtk.Box = null, tile: ?*gtk.Widget = null };

/// One row the sidebar should have, worked out from the servers before any widget is touched.
const RowPlan = struct {
    kind: enum { host, session, window, agent },
    /// Everything about the row that is built into its widgets. Rows whose keys match what is
    /// on screen are updated where they are, so menus stay open and hover and scroll are kept.
    key: u64,
    host: *Host,
    session: ?*const server_mod.Session = null,
    view: ?*const view.SessionView = null,
    window: ?*const view.Window = null,
    collapsed: bool = false,
    /// For an agent's row: the pane it runs in.
    block_id: []const u8 = "",
};

/// What a sidebar row or a tab shows now, to update it in place.
const RowMark = struct {
    key: u64,
    label: ?*gtk.Label = null,
    line: ?*gtk.Box = null,
    tile: ?*gtk.Widget = null,
    /// The panes the tile was made for; another set needs another tile.
    tile_for: u64 = 0,
    button: ?*gtk.Widget = null,
    /// For an agent's row: its status in a word, and how long it has been so.
    sub: ?*gtk.Label = null,
    when: ?*gtk.Label = null,
};

fn hashParts(parts: []const []const u8) u64 {
    var hasher = std.hash.Wyhash.init(parts.len);
    for (parts) |part| {
        hasher.update(std.mem.asBytes(&part.len));
        hasher.update(part);
    }
    return hasher.final();
}

/// The panes a window's tile draws: the focused one first, then all of them, as `rowTile` reads.
fn tileFor(w: *const view.Window) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(w.focused_block_id orelse "");
    for (w.layers) |l| for (l.blocks) |b| {
        hasher.update(std.mem.asBytes(&b.id.len));
        hasher.update(b.id);
    };
    return hasher.final();
}

/// One Rex server Renux is connected to, with its own workspace page.
pub const Host = struct {
    app: *App,
    label: []u8,
    server: *Server,
    workspace: *Workspace,
    page: [:0]u8,
    /// Set for a host from $RENUX_SERVER, which isn't saved.
    temporary: bool = false,
    muted_tabs: std.StringHashMapUnmanaged(void) = .empty,

    /// Its number among every host this run, which no later host shares.
    serial: usize = 0,
    /// Holds the last frame drawn of the host's panes, for the overview to zoom out from.
    shot: *gtk.WidgetPaintable,

    /// Whether the host is another computer: anything not reached through a socket here.
    pub fn remote(h: *const Host) bool {
        return !std.mem.startsWith(u8, h.server.url, "unix://");
    }
};

/// A host as a dialog remembers it. The host may be removed while the dialog is open, so the
/// dialog asks `App.liveHost` for it again before acting.
const HostRef = struct { host: *Host, serial: usize };

pub const App = struct {
    app: *adw.Application,
    window: *adw.ApplicationWindow = undefined,
    active_prompt: ?*ActivePrompt = null,
    toasts: *adw.ToastOverlay = undefined,
    /// The message showing at the bottom, its text, and how many times in a row it was said.
    toast_now: ?*adw.Toast = null,
    toast_text: std.ArrayList(u8) = .empty,
    toast_count: u32 = 0,
    sidebar: *gtk.ListBox = undefined,
    /// Over the sidebar's list, for the picture of a session being dragged to another place.
    sidebar_layer: *gtk.Fixed = undefined,
    sidebar_scroller: *gtk.ScrolledWindow = undefined,
    /// A press on a session's heading that may become a drag: where it took hold, and whether
    /// it has moved far enough to be one.
    session_grab_y: f64 = 0,
    session_dragging: bool = false,
    session_drag_refused: bool = false,
    /// The sessions being reordered, top to bottom, and their host.
    drag_host: ?HostRef = null,
    drag_ids: std.ArrayList([]u8) = .empty,
    split: *adw.OverlaySplitView = undefined,
    card: *gtk.Widget = undefined,
    /// The window's see-through background, one even layer under everything, panes included.
    window_bg: *gtk.Widget = undefined,
    /// The window's one cursor, as the cursor shader draws it, over every pane.
    cursor_layer: *gtk.Widget = undefined,
    corner: *gtk.Widget = undefined,
    /// The window's own buttons in the corner, which Settings can take away.
    corner_controls: *gtk.Widget = undefined,
    /// The window draws no background of its own: only the cards show, with no corner.
    bare: bool = false,
    corner_tick: c_uint = 0,
    corner_until: i64 = 0,
    stack: *gtk.Stack = undefined,
    status: *adw.StatusPage = undefined,
    retry_button: *gtk.Button = undefined,
    entry: *gtk.Entry = undefined,
    /// The host whose session is shown; `server` and `workspace` are its.
    server: ?*Server = null,
    workspace: ?*Workspace = null,
    current: ?*Host = null,
    hosts: std.ArrayList(*Host) = .empty,
    /// The host the sidebar is narrowed to, or null for all of them.
    filter: ?*Host = null,
    next_page: usize = 0,
    filter_button: *gtk.MenuButton = undefined,
    sidebar_menu: *gio.Menu = undefined,
    header_room: *gtk.Widget = undefined,
    side_root: *gtk.Widget = undefined,
    /// The sidebar itself, a card of its own while the window has no background.
    side_card: *gtk.Widget = undefined,
    /// What the desktop was last asked to blur and nothing else, while the window has no
    /// background; `frost`.
    frost_now: std.ArrayList(wayland.Part) = .empty,
    frost_sent: std.ArrayList(wayland.Part) = .empty,
    frost_said: u32 = 0,
    frosting: bool = false,
    /// Holds the sidebar, and slides it out from under the panes while the window has no
    /// background.
    side_slide: *gtk.Widget = undefined,
    sidebar_handle: *gtk.Widget = undefined,
    sidebar_drag_start: ?f64 = null,
    board: *@import("../ui/board.zig").Board = undefined,
    /// Every tab at once, small, over the panes while it is open.
    overview: *@import("../ui/overview.zig").Overview = undefined,
    board_button: *gtk.ToggleButton = undefined,
    overview_button: *gtk.Widget = undefined,
    eye_button: *gtk.ToggleButton = undefined,
    /// Runs while the sidebar fades out, before it changes between every tab and agents only.
    eye_swap: c_uint = 0,
    /// The sidebar was hidden when the keyboard was sent to it, and hides again after.
    sidebar_peek: bool = false,
    eye_dot: *gtk.Widget = undefined,
    /// The sidebar lists only agents, each with its status.
    agents_only: bool = false,
    agents_clock: c_uint = 0,
    config_timer: c_uint = 0,
    filter_menu: *gio.Menu = undefined,
    mode_chip: *gtk.Label = undefined,
    /// The keys that can follow a prefix or work in a key mode, while one is waiting.
    hints: *gtk.Box = undefined,
    /// The session's windows as tabs above the panes, when tabs go there.
    tab_strip: *gtk.Box = undefined,
    activity: *@import("../ui/activity.zig").Activity = undefined,
    /// A pane being floated so it can be minimized.
    minimize_next: ?[]u8 = null,
    rows: std.ArrayList(?Row) = .empty,
    /// One for each sidebar row, in the same order as `rows`, and one for each tab.
    row_marks: std.ArrayList(RowMark) = .empty,
    tab_marks: std.ArrayList(RowMark) = .empty,
    /// What the tab strip was last built for, besides its tabs.
    tabs_key: u64 = 0,
    /// The sidebar or the tabs wait to be brought up to date, once, before the next frame.
    sidebar_stale: bool = false,
    tabs_stale: bool = false,
    refresh_idle: c_uint = 0,
    /// What the corner's room was last measured for: the shown tab and its top-left pane.
    corner_for: u64 = 0,
    /// Sessions whose windows are folded away in the sidebar.
    collapsed: std.StringHashMapUnmanaged(void) = .empty,
    /// The window the person is looking at, which may differ from the session's active one.
    session_id: ?[]u8 = null,
    window_id: ?[]u8 = null,
    rebuilding: bool = false,
    was_online: bool = false,
    /// The shown session was chosen by the app, not the person.
    auto_picked: bool = false,
    theme_css: ?*gtk.CssProvider = null,
    look_css: ?*gtk.CssProvider = null,
    last_dark: bool = true,
    badge_count: u32 = 0,
    awake: @import("awake.zig").Inhibitor = .{},
    /// The session bus the launcher badge is sent on, once it has answered.
    badge_bus: ?*gio.DBusConnection = null,
    badge_bus_asked: bool = false,
    /// The shown window's tiled pane count, to balance splits when it changes.
    balance_count: usize = 0,
    balance_window: [64]u8 = undefined,
    balance_window_len: usize = 0,
    theme_for: ?@import("../rex/stream.zig").Colors = null,
    /// The terminal options last applied, so a change to one redoes only that one's work.
    applied_text: TextSetup = .{},
    applied_extended: bool = false,
    /// Each pane's folder as last seen, hashed, to tell a move from a repeat.
    block_folders: std.AutoHashMapUnmanaged(u64, u64) = .empty,

    pub fn create() !*App {
        const a = try gpa.create(App);
        // Each window is its own process, so a second launch opens a second window.
        a.* = .{ .app = adw.Application.new("dev.renux", .{ .non_unique = true }) };
        _ = gio.Application.signals.activate.connect(a.app, *App, &activate, a, .{});
        return a;
    }

    pub fn run(a: *App) c_int {
        const code = a.app.as(gio.Application).run(0, null);
        for (a.hosts.items) |h| if (h.server.ssh) |t| t.stop();
        return code;
    }

    fn closingWindow(_: *gtk.Window, a: *App) callconv(.c) c_int {
        // GTK drops its inhibitor backend during shutdown, before that signal reaches us.
        a.awake.release(a.app.as(gtk.Application));
        return 0;
    }

    pub fn awakeChanged(a: *App) void {
        a.awake.sync(a);
    }

    fn activate(_: *adw.Application, a: *App) callconv(.c) void {
        // GTK may have reset it while starting up.
        if (builtin.os.tag == .macos and std.c.getenv("RENUX_NOFOCUS") != null) @import("../platform/macos.zig").neverActivate();
        settings.load();
        // Asked before Renux forces a scheme of its own, while libadwaita still reports the
        // desktop's preference: dark only when the desktop prefers dark.
        if (builtin.os.tag != .macos) linux_dark = adw.StyleManager.getDefault().getDark() != 0;
        termview.pad_x = settings.current.pad_x;
        termview.pad_y = settings.current.pad_y;
        a.applied_text = TextSetup.now();
        a.applied_extended = settings.current.extended_palette;
        {
            const name: ?[:0]u8 = gpa.dupeSentinel(u8, if (std.c.getenv("RENUX_FONT")) |f| std.mem.span(f) else settings.current.font, 0) catch null;
            defer if (name) |z| gpa.free(z);
            termview.font = termview.Font.init(name orelse "Monospace 11");
        }
        const provider = gtk.CssProvider.new();
        provider.loadFromString(css);
        gtk.StyleContext.addProviderForDisplay(gdk.Display.getDefault().?, provider.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

        a.applyTheme();
        useAppIcon();
        a.window = adw.ApplicationWindow.new(a.app.as(gtk.Application));
        const win = a.window.as(gtk.Window);
        _ = gtk.Window.signals.close_request.connect(win, *App, &closingWindow, a, .{});
        win.setDefaultSize(1180, 760);
        // Development: RENUX_SIZE=WIDTHxHEIGHT starts the window at another size, and keeps it
        // there even on a smaller screen, for screenshots.
        if (build_options.dev) if (std.c.getenv("RENUX_SIZE")) |size| {
            var parts = std.mem.splitScalar(u8, std.mem.span(size), 'x');
            const w = std.fmt.parseInt(c_int, parts.first(), 10) catch 1180;
            const h = std.fmt.parseInt(c_int, parts.next() orelse "760", 10) catch 760;
            win.setDefaultSize(w, h);
            win.as(gtk.Widget).setSizeRequest(w, h);
        };
        win.setTitle("Renux");
        win.as(gtk.Widget).addCssClass("renux");

        // Sidebar: window controls and a menu on top, sessions and their windows, then a footer.
        a.sidebar = gtk.ListBox.new();
        a.sidebar.as(gtk.Widget).addCssClass("navigation-sidebar");
        _ = gtk.ListBox.signals.row_activated.connect(a.sidebar, *App, &rowActivated, a, .{});
        const scroller = gtk.ScrolledWindow.new();
        scroller.setPolicy(.never, .external);
        scroller.setChild(a.sidebar.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);
        a.sidebar_scroller = scroller;
        a.sidebar_layer = gtk.Fixed.new();
        a.sidebar_layer.as(gtk.Widget).setCanTarget(0);
        a.sidebar_layer.as(gtk.Widget).setOverflow(.hidden);
        const side_stack = gtk.Overlay.new();
        side_stack.setChild(scroller.as(gtk.Widget));
        side_stack.addOverlay(a.sidebar_layer.as(gtk.Widget));
        side_stack.as(gtk.Widget).setVexpand(1);
        // The window controls and the sidebar toggle sit in a fixed corner above everything, so the
        // toggle never moves; the sidebar header leaves room for it, and so does the top-left pane
        // while the sidebar is hidden.
        const corner_size = gtk.SizeGroup.new(.horizontal);
        const corner = gtk.Box.new(.horizontal, 4);
        corner.as(gtk.Widget).addCssClass("window-corner");
        // The window's buttons sit in the corner with the sidebar toggle, like Rex's: the desktop's
        // own buttons, in its order, all moved to the left.
        const controls = gtk.WindowControls.new(.start);
        controls.setDecorationLayout(cornerLayout().ptr);
        controls.as(gtk.Widget).addCssClass("corner-controls");
        controls.as(gtk.Widget).setVisible(@intFromBool(settings.current.window_buttons));
        a.corner_controls = controls.as(gtk.Widget);
        corner.append(controls.as(gtk.Widget));
        corner.append(icons.button(.sidebar, "Toggle sidebar", "app.toggle-sidebar").as(gtk.Widget));
        corner.as(gtk.Widget).setHalign(.start);
        corner.as(gtk.Widget).setValign(.start);
        corner_size.addWidget(corner.as(gtk.Widget));
        const side_header = gtk.WindowHandle.new();
        side_header.as(gtk.Widget).addCssClass("sidebar-header");
        const head_tools = sidebar_tools.new();
        side_header.setChild(head_tools.as(gtk.Widget));
        a.header_room = gtk.Box.new(.horizontal, 0).as(gtk.Widget);
        a.header_room.setHexpand(1);
        corner_size.addWidget(a.header_room);
        corner_size.as(gobject.Object).unref();
        head_tools.append(a.header_room);
        head_tools.append(icons.button(.gear, "Settings", "app.settings").as(gtk.Widget));
        head_tools.append(icons.button(.search, "Commands", "app.palette").as(gtk.Widget));
        // The eye: with it on, the sidebar lists only agents and how each is doing. Its dot
        // says, also while it is off, that an agent needs you, failed, or has finished unseen.
        a.eye_button = gtk.ToggleButton.new();
        const eye_art = gtk.Overlay.new();
        eye_art.setChild(icons.image(.eye, 16));
        // As small as the eye itself, so the dot sits on the eye's corner, inside the button:
        // at the button's own corner it reached past the header's edge, which cuts it off.
        eye_art.as(gtk.Widget).setHalign(.center);
        eye_art.as(gtk.Widget).setValign(.center);
        a.eye_dot = gtk.Box.new(.horizontal, 0).as(gtk.Widget);
        a.eye_dot.addCssClass("eye-dot");
        a.eye_dot.setHalign(.end);
        a.eye_dot.setValign(.start);
        a.eye_dot.setVisible(0);
        eye_art.addOverlay(a.eye_dot);
        a.eye_button.as(gtk.Button).setChild(eye_art.as(gtk.Widget));
        a.eye_button.as(gtk.Widget).setTooltipText("Show only agents");
        a.eye_button.as(gtk.Widget).addCssClass("icon-button");
        a.eye_button.as(gtk.Widget).addCssClass("flat");
        a.eye_button.as(gtk.Widget).setValign(.center);
        _ = gtk.ToggleButton.signals.toggled.connect(a.eye_button, *App, &eyeToggled, a, .{});
        head_tools.append(a.eye_button.as(gtk.Widget));
        // The footer, like Rex's: narrow the sidebar to one host, a new session, and another host.
        const footer = gtk.Box.new(.horizontal, 2);
        footer.as(gtk.Widget).addCssClass("sidebar-footer");
        a.filter_button = gtk.MenuButton.new();
        steadyMenu(a.filter_button);
        a.filter_button.setChild(icons.image(.filter, 16));
        a.filter_button.as(gtk.Widget).addCssClass("filter-pill");
        // Plain like the buttons beside it until a host is picked; then it lights up.
        a.filter_button.as(gtk.Widget).addCssClass("flat");
        a.filter_button.as(gtk.Widget).setTooltipText("Show one host or all of them");
        a.filter_menu = gio.Menu.new();
        a.filter_button.setMenuModel(a.filter_menu.as(gio.MenuModel));
        footer.append(a.filter_button.as(gtk.Widget));
        // A button that stays lit while the board is open: pressed again, or with another
        // pane picked in the sidebar, it goes out and the panes are back.
        a.board_button = gtk.ToggleButton.new();
        a.board_button.as(gtk.Button).setChild(icons.image(.board, 16));
        a.board_button.as(gtk.Widget).setTooltipText("Agent board");
        a.board_button.as(gtk.Widget).addCssClass("icon-button");
        a.board_button.as(gtk.Widget).addCssClass("flat");
        a.board_button.as(gtk.Widget).setValign(.center);
        _ = gtk.ToggleButton.signals.toggled.connect(a.board_button, *App, &boardToggled, a, .{});
        const foot_tools = sidebar_tools.new();
        footer.append(foot_tools.as(gtk.Widget));
        foot_tools.append(a.board_button.as(gtk.Widget));
        a.overview_button = icons.button(.overview, "Overview of every tab", "app.overview").as(gtk.Widget);
        foot_tools.append(a.overview_button);
        a.board_button.as(gtk.Widget).setVisible(@intFromBool(settings.current.agent_board));
        a.overview_button.setVisible(@intFromBool(settings.current.overview));
        foot_tools.append(icons.button(.add_host, "Add remote host", "app.add-host").as(gtk.Widget));
        foot_tools.append(icons.button(.new_session, "New session", "app.new-session").as(gtk.Widget));
        a.sidebar_menu = gio.Menu.new();
        a.fillSidebarMenu();
        footer.append(menuButton(a.sidebar_menu.as(gio.MenuModel), "Sidebar actions").as(gtk.Widget));
        const side = adw.ToolbarView.new();
        side.as(gtk.Widget).addCssClass("renux-sidebar");
        side.addTopBar(side_header.as(gtk.Widget));
        side.addBottomBar(footer.as(gtk.Widget));
        side.setContent(side_stack.as(gtk.Widget));

        // Content: the panes, each its own card, on the window's background. While the sidebar is
        // hidden, the top-left pane's title makes room for the corner.
        a.corner = corner.as(gtk.Widget);
        a.stack = gtk.Stack.new();
        a.stack.setTransitionType(.crossfade);
        a.stack.as(gtk.Widget).addCssClass("panes");
        a.stack.as(gtk.Widget).setVexpand(1);
        a.status = adw.StatusPage.new();
        a.retry_button = gtk.Button.newWithLabel("Try again");
        a.retry_button.as(gtk.Widget).addCssClass("pill");
        a.retry_button.as(gtk.Widget).setHalign(.center);
        a.retry_button.as(gtk.Actionable).setActionName("app.retry");
        a.status.setChild(a.retry_button.as(gtk.Widget));
        _ = a.stack.addNamed(a.status.as(gtk.Widget), "status");
        _ = a.stack.addNamed(a.connectPage(), "connect");

        // Keys belong to the highlighted pane wherever the keyboard happens to sit: on a button
        // just clicked, a sidebar row, another pane, or nowhere after a pane closed.
        const stray = gtk.EventControllerKey.new();
        stray.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(stray, *App, &strayKey, a, .{});
        win.as(gtk.Widget).addController(stray.as(gtk.EventController));

        const card = gtk.Box.new(.vertical, 0);
        card.as(gtk.Widget).addCssClass("content");
        // Two fingers sideways on a trackpad switch tabs, like Rex.
        // Both directions are heard, though only sideways swipes act: without the up and down
        // part there is no telling a swipe from the sideways drift of ordinary scrolling.
        const swipe = gtk.EventControllerScroll.new(.{ .horizontal = true, .vertical = true });
        swipe.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerScroll.signals.scroll.connect(swipe, *App, &swiped, a, .{});
        _ = gtk.EventControllerScroll.signals.scroll_end.connect(swipe, *App, &swipeEnded, a, .{});
        a.stack.as(gtk.Widget).addController(swipe.as(gtk.EventController));
        a.tab_strip = gtk.Box.new(.horizontal, 4);
        a.tab_strip.as(gtk.Widget).addCssClass("tab-strip");
        a.tab_strip.as(gtk.Widget).setVisible(0);
        card.append(a.tab_strip.as(gtk.Widget));
        // The agent board lies over the panes while it is open.
        a.board = @import("../ui/board.zig").Board.create(a);
        a.board.widget().setCanTarget(0);
        const body = gtk.Overlay.new();
        body.setChild(a.stack.as(gtk.Widget));
        body.addOverlay(a.board.widget());
        a.overview = @import("../ui/overview.zig").Overview.create(a);
        body.addOverlay(a.overview.widget());
        body.as(gtk.Widget).setVexpand(1);
        card.append(body.as(gtk.Widget));
        a.card = card.as(gtk.Widget);

        const split = adw.OverlaySplitView.new();
        a.split = split;
        // The inner edge is the hit target, but drag offsets belong to the stationary split.
        const side_overlay = gtk.Overlay.new();
        // Without the window's background the sidebar is a card of its own, with round corners that cut
        // what is in it, and comes out from under the panes (`sidebar_slide.zig`).
        side.as(gtk.Widget).setOverflow(.hidden);
        a.side_card = side.as(gtk.Widget);
        a.side_slide = sidebar_slide.new(side.as(gtk.Widget));
        sidebar_slide.within = split.as(gtk.Widget);
        side_overlay.setChild(a.side_slide);
        side_overlay.as(gtk.Widget).setOverflow(.hidden);
        const handle = gtk.Box.new(.vertical, 0);
        handle.as(gtk.Widget).addCssClass("sidebar-handle");
        a.sidebar_handle = handle.as(gtk.Widget);
        handle.as(gtk.Widget).setSizeRequest(8, -1);
        handle.as(gtk.Widget).setCursorFromName("col-resize");
        const handle_drag = gtk.GestureDrag.new();
        handle_drag.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.GestureDrag.signals.drag_begin.connect(handle_drag, *App, &sidebarDragBegin, a, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(handle_drag, *App, &sidebarDragUpdate, a, .{});
        _ = gtk.GestureDrag.signals.drag_end.connect(handle_drag, *App, &sidebarDragEnd, a, .{});
        _ = gtk.Gesture.signals.cancel.connect(handle_drag, *App, &sidebarDragCancel, a, .{});
        split.as(gtk.Widget).addController(handle_drag.as(gtk.EventController));
        side_overlay.addOverlay(handle.as(gtk.Widget));
        split.setSidebar(side_overlay.as(gtk.Widget));
        a.side_root = side_overlay.as(gtk.Widget);
        split.setContent(card.as(gtk.Widget));
        split.setSidebarWidthUnit(.px);
        split.setSidebarWidthFraction(1);
        _ = gobject.Object.signals.notify.connect(split, *App, &sidebarShown, a, .{ .detail = "show-sidebar" });

        a.toasts = adw.ToastOverlay.new();
        const layered = gtk.Overlay.new();
        layered.setChild(split.as(gtk.Widget));
        // The cursor shader's layer lies over the panes, under the window's own buttons.
        const cursor_layer = @import("../ui/cursor_layer.zig");
        a.cursor_layer = cursor_layer.CursorLayer.new().as(gtk.Widget);
        cursor_layer.current = &cursorPane;
        termview.on_drawn = &paneDrawn;
        @import("../ui/workspace.zig").drawn = &panesDrawn;
        layered.addOverlay(a.cursor_layer);
        layered.addOverlay(corner.as(gtk.Widget));
        // Which Rex key mode is on, such as resize, while one is.
        a.mode_chip = gtk.Label.new("");
        a.mode_chip.setEllipsize(.middle);
        a.mode_chip.setMaxWidthChars(80);
        a.mode_chip.as(gtk.Widget).addCssClass("mode-chip");
        a.mode_chip.as(gtk.Widget).setHalign(.center);
        a.mode_chip.as(gtk.Widget).setValign(.end);
        a.mode_chip.as(gtk.Widget).setMarginBottom(18);
        // The chip and the hints are always there, see-through until their `shown` class fades
        // and slides them in; hiding fades them out the same way with what they last showed.
        a.mode_chip.as(gtk.Widget).setCanTarget(0);
        layered.addOverlay(a.mode_chip.as(gtk.Widget));
        a.hints = gtk.Box.new(.vertical, 0);
        a.hints.as(gtk.Widget).addCssClass("key-hints");
        a.hints.as(gtk.Widget).setHalign(.center);
        a.hints.as(gtk.Widget).setValign(.end);
        a.hints.as(gtk.Widget).setMarginBottom(62);
        a.hints.as(gtk.Widget).setCanTarget(0);
        layered.addOverlay(a.hints.as(gtk.Widget));
        a.activity = @import("../ui/activity.zig").Activity.create(a);
        a.activity.widget().setMarginTop(6);
        a.activity.widget().setMarginBottom(8);
        a.activity.widget().setMarginEnd(8);
        layered.addOverlay(a.activity.widget());
        mode_app = a;
        termview.on_mode_changed = modeChanged;
        termview.on_chord_changed = chordChanged;
        termview.TermView.enablePerfLog();
        a.toasts.setChild(layered.as(gtk.Widget));
        // The window's background while see-through lies under everything else.
        const window_bg = @import("../ui/window_bg.zig");
        a.window_bg = window_bg.WindowBackground.new().as(gtk.Widget);
        a.window_bg.setVisible(0);
        @import("../terminal/shader.zig").on_error = &shaderError;
        const base = gtk.Overlay.new();
        base.setChild(a.window_bg);
        base.addOverlay(a.toasts.as(gtk.Widget));
        base.setMeasureOverlay(a.toasts.as(gtk.Widget), 1);
        a.window.setContent(base.as(gtk.Widget));

        a.addActions();
        a.setTight(settings.current.tight);
        a.tabsChanged();
        themes.active = themes.resolve(effectiveTheme());
        a.last_dark = systemDark();
        // The Mac is asked every few seconds; a Linux desktop says when its appearance changes.
        if (builtin.os.tag == .macos) {
            _ = glib.timeoutAddSeconds(3, &appearanceTick, a);
        } else a.watchAppearance();
        @import("../ui/workspace.zig").show_headers = settings.current.show_headers;
        a.markHeaders();
        // The development hooks (screenshots, the test script) are only in `-Ddev` builds.
        if (build_options.dev) installShotHook(a);

        // $RENUX_SERVER, for testing, names hosts to use without saving them, separated by commas.
        if (std.c.getenv("RENUX_SERVER")) |env| {
            var it = std.mem.tokenizeScalar(u8, std.mem.span(env), ',');
            while (it.next()) |url| if (a.addHost(settings.labelFor(url), url)) |h| {
                h.temporary = true;
            };
        } else for (settings.current.hosts.items) |h| _ = a.addHost(h.label, h.url);
        // With no server set, use this computer's own, as the rex command does; connecting
        // starts it when it isn't running.
        if (a.hosts.items.len == 0) if (@import("manage.zig").localServerUrl()) |url| {
            defer gpa.free(url);
            settings.addHost(settings.labelFor(url), url);
            _ = a.addHost(settings.labelFor(url), url);
        };
        updates_app = a;
        updates.changed = &updateKnown;
        if (a.hosts.items.len == 0) a.stack.setVisibleChildName("connect");
        // When driven by tests, show the window without taking the keyboard from what the person
        // is using; otherwise their typing lands in Renux.
        const dev_shot = build_options.dev and std.c.getenv("RENUX_SHOT") != null;
        if (dev_shot) win.as(gtk.Widget).setVisible(1) else if (settings.current.show_on_launch) win.present() else win.as(gtk.Widget).realize();
        @import("warm.zig").start(win.as(gtk.Window));
        _ = gobject.Object.signals.notify.connect(win, ?*anyopaque, &fullscreenChanged, null, .{ .detail = "fullscreened" });
        a.watchConfig();
        // `renux --toggle` finds this process by its ID and signals it.
        if (!dev_shot) {
            @import("../main.zig").claimToggle();
            _ = @import("glibunix").signalAdd(@backingInt(std.posix.SIG.USR1), &toggleSignal, a);
        }
        if (build_options.dev and std.c.getenv("RENUX_PERF") != null) if (win.as(gtk.Widget).getFrameClock()) |clock| {
            FrameLog.watch(clock);
            FrameLog.watchPointer(win.as(gtk.Widget));
        };
        if (!settings.current.welcomed and !dev_shot) @import("manage.zig").openWelcome(a);
        a.applyLook();
        _ = gobject.Object.signals.notify.connect(win, *App, &activeChanged, a, .{ .detail = "is-active" });
    }

    /// The desktop's button layout with every button on the left, such as "close" from GNOME's
    /// "appmenu:close".
    fn cornerLayout() [:0]const u8 {
        const S = struct {
            var buf: [128]u8 = undefined;
        };
        var value: ?[*:0]u8 = null;
        if (gtk.Settings.getDefault()) |gs| gobject.Object.get(gs.as(gobject.Object), "gtk-decoration-layout", &value, @as(?*anyopaque, null));
        const raw = if (value) |v| std.mem.span(v) else "close,minimize,maximize";
        defer if (value) |v| glib.free(v);
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, raw, ",:");
        while (it.next()) |b| {
            // The app menu and icon have no place in the corner.
            if (std.mem.eql(u8, b, "appmenu") or std.mem.eql(u8, b, "icon")) continue;
            if (n + b.len + 2 >= S.buf.len) break;
            if (n > 0) {
                S.buf[n] = ',';
                n += 1;
            }
            @memcpy(S.buf[n .. n + b.len], b);
            n += b.len;
        }
        S.buf[n] = ':';
        S.buf[n + 1] = 0;
        return S.buf[0 .. n + 1 :0];
    }

    fn setSidebarWidth(a: *App, width: f64) void {
        const w = @round(std.math.clamp(width, settings.sidebar_min, 480));
        if (a.sidebar_drag_start != null and w == a.split.getMaxSidebarWidth()) return;
        a.split.setMaxSidebarWidth(w);
        a.split.setMinSidebarWidth(w);
        // The split view gives a sidebar no more than its contents ask for, whatever the
        // maximum says, so the sidebar asks for exactly the width picked. Without this it sat
        // at its header's width and jumped whenever that changed.
        a.side_root.setSizeRequest(@intFromFloat(w), -1);
        a.cornerChanged();
    }

    fn fillSidebarMenu(a: *App) void {
        const menu = a.sidebar_menu;
        menu.removeAll();
        menu.append("New Session…", "app.new-session");
        menu.append("Add Remote Host…", "app.add-host");
        menu.append(if (a.agents_only) "Show All Sessions" else "Show Only Agents", "app.agents");
        if (settings.current.agent_board) menu.append("Agent Board", "app.board");
        if (settings.current.overview) menu.append("Overview", "app.overview");
        menu.append("Commands…", "app.palette");
        menu.append("Settings…", "app.settings");
    }

    /// Watches the settings file and the themes folder, so a change made outside this window
    /// takes effect at once: a script that switches color themes, another Renux window, an
    /// editor. Folders are watched rather than files, since most programs save by writing a
    /// new file over the old one.
    fn watchConfig(a: *App) void {
        const config = settings.folder() orelse return;
        defer gpa.free(config);
        _ = glib.mkdirWithParents(config.ptr, 0o700);
        const themes_dir = @import("../settings/theme_editor.zig").dir();
        defer if (themes_dir) |d| gpa.free(d);
        if (themes_dir) |d| _ = glib.mkdirWithParents(d.ptr, 0o700);
        inline for (.{ @as(?[:0]u8, config), themes_dir }) |maybe| if (maybe) |path| {
            const folder = gio.File.newForPath(path.ptr);
            defer folder.as(gobject.Object).unref();
            // The monitor is kept for the life of the app.
            if (folder.monitorDirectory(.{ .watch_moves = true }, null, null)) |monitor| {
                _ = gio.FileMonitor.signals.changed.connect(monitor, *App, &configChanged, a, .{});
            }
        };
    }

    fn configChanged(_: *gio.FileMonitor, _: *gio.File, _: ?*gio.File, _: gio.FileMonitorEvent, a: *App) callconv(.c) void {
        // A save is several events in a row; they are taken up together a moment later.
        if (a.config_timer != 0) _ = glib.Source.remove(a.config_timer);
        a.config_timer = glib.timeoutAdd(120, &configSettled, a);
    }

    fn configSettled(data: ?*anyopaque) callconv(.c) c_int {
        const a: *App = @ptrCast(@alignCast(data.?));
        a.config_timer = 0;
        if (settings.reload()) {
            a.themeChanged();
            a.fontChanged();
            a.terminalChanged();
            a.tabsChanged();
            a.headersChanged();
            a.viewsChanged();
            a.awakeChanged();
            a.applyLook();
            a.setTight(settings.current.tight);
            a.redrawAll();
        } else if (std.mem.startsWith(u8, effectiveTheme(), "file:")) {
            // The settings are the same, but the theme file in use may be what changed.
            a.themeChanged();
        }
        return 0;
    }

    fn toggleBoard(a: *App) void {
        a.showBoard(!a.board.shown());
    }

    /// Shows the agent board over the panes, or goes back to them.
    pub fn showBoard(a: *App, on: bool) void {
        if (on and !settings.current.agent_board) return;
        // The board and going to a pane both leave the overview.
        const from_overview = a.overview.shown();
        a.overview.hideNow();
        if (on == a.board.shown()) return;
        a.board.show(on);
        a.frost();
        // The board is see-through when the window is, so the panes under it are hidden while
        // it is open. They fade out under it as it fades in: gone at once, they left nothing
        // on screen for a moment, which without the window's background was the bare desktop. They are
        // back at once when it goes, under what is left of it. From the overview they were
        // hidden already and stay so.
        const stack = a.stack.as(gtk.Widget);
        if (on and from_overview) stack.addCssClass("at-once") else stack.removeCssClass("at-once");
        if (on) stack.addCssClass("under-board") else stack.removeCssClass("under-board");
        // The button shows which it is; setting it runs `boardToggled`, which finds nothing
        // left to do.
        a.board_button.setActive(@intFromBool(on));
        if (!on) if (a.workspace) |ws| ws.grabFocus();
    }

    fn toggleAgents(a: *App) void {
        a.eye_button.setActive(@intFromBool(a.eye_button.getActive() == 0));
    }

    /// The eye was clicked: the sidebar fades out, changes between every tab and agents only
    /// while it is clear, and fades back in with the new rows.
    fn eyeToggled(_: *gtk.ToggleButton, a: *App) callconv(.c) void {
        a.sidebar.as(gtk.Widget).addCssClass("swapping");
        if (a.eye_swap == 0) a.eye_swap = glib.timeoutAdd(120, &eyeSwap, a);
    }

    fn eyeSwap(data: ?*anyopaque) callconv(.c) c_int {
        const a: *App = @ptrCast(@alignCast(data.?));
        a.eye_swap = 0;
        a.agents_only = a.eye_button.getActive() != 0;
        a.fillSidebarMenu();
        // "4 min" beside each agent is kept up to date while they are listed.
        if (a.agents_clock != 0) _ = glib.Source.remove(a.agents_clock);
        a.agents_clock = if (a.agents_only) glib.timeoutAddSeconds(30, &agentsTick, a) else 0;
        a.rebuildSidebar();
        a.refreshNow();
        a.sidebar.as(gtk.Widget).removeCssClass("swapping");
        return 0;
    }

    /// Sends the keyboard to the sidebar, on the row of the tab being shown: j and k (or the
    /// arrows) step through the rows, Ctrl+D and Ctrl+U jump half a screen, g and G go to the
    /// ends, Enter opens the row, and Escape goes back to the pane. A hidden sidebar shows
    /// for as long as this lasts.
    fn focusSidebar(a: *App) void {
        if (a.split.getShowSidebar() == 0) {
            a.sidebar_peek = true;
            a.split.setShowSidebar(1);
        }
        if (a.sidebar_stale) a.refreshNow();
        var at: ?usize = null;
        if (a.sidebar.getSelectedRow()) |row| {
            const i = row.getIndex();
            if (i >= 0) at = @intCast(i);
        }
        const start = at orelse a.pickableFrom(0, 1) orelse return a.leaveSidebar();
        a.focusSidebarRow(start);
    }

    fn focusSidebarRow(a: *App, index: usize) void {
        const row = a.sidebar.getRowAtIndex(@intCast(index)) orelse return;
        // The ring that marks the row with the keyboard shows only for keyboard focus.
        a.window.as(gtk.Window).setFocusVisible(1);
        _ = row.as(gtk.Widget).grabFocus();
    }

    /// The keyboard goes back to the pane, and a sidebar shown only for this hides again.
    fn leaveSidebar(a: *App) void {
        if (a.sidebar_peek) {
            a.sidebar_peek = false;
            a.split.setShowSidebar(0);
        }
        if (a.workspace) |w| w.grabFocus();
    }

    /// The first row that opens something, looking from `from` in steps of `step`: headings
    /// are passed over.
    fn pickableFrom(a: *App, from: usize, step: isize) ?usize {
        var i: isize = @intCast(from);
        while (i >= 0 and i < a.rows.items.len) : (i += step) {
            if (a.rows.items[@intCast(i)] != null) return @intCast(i);
        }
        return null;
    }

    /// The sidebar row that has the keyboard, if one does.
    fn sidebarCursor(a: *App) ?usize {
        const focus = a.window.as(gtk.Window).getFocus() orelse return null;
        const row = gobject.ext.cast(gtk.ListBoxRow, focus) orelse return null;
        if (row.as(gtk.Widget).getParent() != a.sidebar.as(gtk.Widget)) return null;
        const i = row.getIndex();
        return if (i >= 0) @intCast(i) else null;
    }

    /// A key while a sidebar row has the keyboard. True when it was one of the sidebar's own.
    fn sidebarKey(a: *App, keyval: c_uint, mods: u4) bool {
        const at = a.sidebarCursor() orelse return false;
        // Half the rows that fit, as Ctrl+D and Ctrl+U move in a pager.
        const fit = @divTrunc(a.sidebar_scroller.as(gtk.Widget).getHeight(), 33 * 2);
        const jump: usize = @intCast(@max(3, fit));
        if (mods == keys.ctrl) switch (keyval) {
            'd', 'D' => a.moveSidebarCursor(at, jump, 1),
            'u', 'U' => a.moveSidebarCursor(at, jump, -1),
            else => return false,
        } else if (mods & ~@as(u4, keys.shift) != 0) {
            return false;
        } else switch (keyval) {
            'j', 0xff54 => a.moveSidebarCursor(at, 1, 1),
            'k', 0xff52 => a.moveSidebarCursor(at, 1, -1),
            'g', 0xff50 => a.moveSidebarCursor(at, a.rows.items.len, -1),
            'G', 0xff57 => a.moveSidebarCursor(at, a.rows.items.len, 1),
            0xff0d, 0xff8d, 'l', 0xff53 => {
                // Opening the row is the list's own doing; the pane then takes the keyboard.
                if (a.sidebar.getRowAtIndex(@intCast(at))) |row| _ = row.as(gtk.Widget).activate();
                a.leaveSidebar();
            },
            0xff1b, 'q', 'h', 0xff51 => a.leaveSidebar(),
            else => return false,
        }
        return true;
    }

    /// Moves the keyboard `count` rows that open something up or down from `at`, stopping at
    /// the last one there is.
    fn moveSidebarCursor(a: *App, at: usize, count: usize, step: isize) void {
        var to = at;
        var left = count;
        while (left > 0) : (left -= 1) {
            const from = @as(isize, @intCast(to)) + step;
            if (from < 0) break;
            to = a.pickableFrom(@intCast(from), step) orelse break;
        }
        if (to != at) a.focusSidebarRow(to);
    }

    fn agentsTick(data: ?*anyopaque) callconv(.c) c_int {
        const a: *App = @ptrCast(@alignCast(data.?));
        a.rebuildSidebar();
        return 1;
    }

    /// Colors the eye's dot for the most pressing thing any agent reports: one needs you, one
    /// failed, or one finished and hasn't been looked at. No dot when there is none of those.
    fn updateEye(a: *App) void {
        var worst: enum { none, done, failed, blocked } = .none;
        for (a.hosts.items) |h| {
            var it = h.server.blocks.valueIterator();
            while (it.next()) |b| {
                if (!b.has_status) continue;
                switch (b.status) {
                    .blocked => worst = .blocked,
                    .failed => if (worst != .blocked) {
                        worst = .failed;
                    },
                    .done => if (worst == .none and b.attention) {
                        worst = .done;
                    },
                    else => {},
                }
            }
        }
        a.eye_dot.setVisible(@intFromBool(worst != .none));
        inline for (.{ "blocked", "failed", "done" }) |class| {
            if (std.mem.eql(u8, class, @tagName(worst))) a.eye_dot.addCssClass(class) else a.eye_dot.removeCssClass(class);
        }
    }

    fn boardToggled(button: *gtk.ToggleButton, a: *App) callconv(.c) void {
        a.showBoard(button.getActive() != 0);
    }

    fn fullscreenChanged(_: *gtk.Window, _: *gobject.ParamSpec, _: ?*anyopaque) callconv(.c) void {
        @import("warm.zig").again();
    }

    fn sidebarDragBegin(g: *gtk.GestureDrag, x: f64, y: f64, a: *App) callconv(.c) void {
        if (a.split.as(gtk.Widget).pick(x, y, .{}) != a.sidebar_handle) {
            _ = g.as(gtk.Gesture).setState(.denied);
            return;
        }
        _ = g.as(gtk.Gesture).setState(.claimed);
        a.sidebar_drag_start = @floatFromInt(a.side_root.getWidth());
        termview.hold_sizes = true;
    }

    /// The drag is over, however it ended: panes take the sizes they now have.
    fn sidebarDragDone(a: *App) void {
        if (a.sidebar_drag_start == null) return;
        a.sidebar_drag_start = null;
        termview.hold_sizes = false;
        for (a.hosts.items) |h| h.workspace.sendSizes();
    }

    fn sidebarDragCancel(_: *gtk.GestureDrag, _: ?*gdk.EventSequence, a: *App) callconv(.c) void {
        a.sidebarDragDone();
    }

    fn sidebarDragUpdate(_: *gtk.GestureDrag, dx: f64, _: f64, a: *App) callconv(.c) void {
        const start = a.sidebar_drag_start orelse return;
        const at_start = a.split.getSidebarPosition() == .start;
        const left = at_start != (a.split.as(gtk.Widget).getDirection() == .rtl);
        a.setSidebarWidth(start + if (left) dx else -dx);
    }

    fn sidebarDragEnd(g: *gtk.GestureDrag, dx: f64, dy: f64, a: *App) callconv(.c) void {
        if (a.sidebar_drag_start == null) return;
        sidebarDragUpdate(g, dx, dy, a);
        const w = a.split.getMaxSidebarWidth();
        if (settings.current.sidebar_width != w) {
            settings.current.sidebar_width = w;
            settings.save();
        }
        a.sidebarDragDone();
    }

    /// A key pressed while the keyboard isn't in the highlighted pane goes to that pane, which
    /// takes the keyboard back, so a prefix such as ctrl+a always works. Text fields, menus and
    /// dialogs keep their keys.
    /// Whether a key is the first of one of Rex's bindings for the host on screen.
    fn beginsBinding(a: *App, keyval: c_uint, mods: u4) bool {
        const s = a.server orelse return false;
        var buf: [40]u8 = undefined;
        const name = keys.rexName(&buf, keyval, gdk.keyvalToUnicode(keyval), mods) orelse return false;
        return termview.beginsBinding(s.keyBindings(), name);
    }

    fn strayKey(ctl: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, state: gdk.ModifierType, a: *App) callconv(.c) c_int {
        switch (a.routeKey(keyval, keys.modsFromGdk(@bitCast(state)))) {
            .taken => return 1,
            .left => return 0,
            .to_pane => {
                const pane = ((a.workspace orelse return 0).focusedView() orelse return 0).widget();
                _ = pane.grabFocus();
                return ctl.forward(pane);
            },
        }
    }

    /// What becomes of a key the window hears first: taken here, left to whatever has the
    /// keyboard, or sent to the highlighted pane.
    const KeyRoute = enum { taken, left, to_pane };

    fn routeKey(a: *App, keyval: c_uint, mods: u4) KeyRoute {
        // The overview is over the panes: arrows move between its tabs, Enter goes to one and
        // Escape goes back. Nothing else is typed into a pane that can't be seen, except Rex's
        // own keys (one that starts a binding, and what follows a prefix), so the key that
        // opened it closes it too.
        if (a.overview.shown()) {
            if (!a.inDialog()) {
                const chord = termview.chordPending();
                if (!chord and a.overview.key(keyval, mods)) return .taken;
                if (!keys.isModifier(keyval) and !chord and !a.beginsBinding(keyval, mods)) return .taken;
            }
        }
        const ws = a.workspace orelse return .left;
        const tv = ws.focusedView() orelse return .left;
        const pane = tv.widget();
        if (pane.getMapped() == 0) return .left;
        if (a.inDialog()) return .left;
        // The board is over the panes too, with keys of its own: h, j, k and l move through
        // its cards. Rex's keys still get through, so the key that opened it closes it.
        if (a.board.shown()) {
            const chord = termview.chordPending();
            if (!chord and a.board.handleKey(keyval, mods)) return .taken;
            if (!keys.isModifier(keyval) and !chord and !a.beginsBinding(keyval, mods)) return .taken;
        }
        // Find in the pane: Command+F on a Mac, Ctrl+Shift+F elsewhere, as terminals have it.
        const find_mods: u4 = if (builtin.os.tag == .macos) keys.super else keys.ctrl | keys.shift;
        if ((keyval == 'f' or keyval == 'F') and mods == find_mods) {
            a.openFind();
            return .taken;
        }
        const focus = a.window.as(gtk.Root).getFocus();
        if (focus) |f| {
            if (f == pane) return .left;
            inline for (.{ gtk.Text, gtk.TextView }) |T| {
                if (f.getAncestor(T.getGObjectType()) != null) return .left;
            }
        }
        if (keys.isModifier(keyval)) return .left;
        // With the keyboard in the activity panel, its keys move through the rows there. Any
        // other key gives the keyboard back to the pane, and the panel stays as it is.
        if (a.activity.cursor() != null) {
            if (a.activity.key(keyval, mods)) return .taken;
            return .to_pane;
        }
        // With the keyboard in the sidebar, its keys move through the rows. Any other key
        // leaves it for the pane, as typing anywhere else does.
        if (a.sidebarCursor() != null) {
            if (a.sidebarKey(keyval, mods)) return .taken;
            if (a.sidebar_peek) {
                a.sidebar_peek = false;
                a.split.setShowSidebar(0);
            }
        }
        return .to_pane;
    }

    /// Whether the keyboard is in a menu or a dialog, which keep their keys.
    fn inDialog(a: *App) bool {
        const f = a.window.as(gtk.Root).getFocus() orelse return false;
        return f.getAncestor(gtk.Popover.getGObjectType()) != null or f.getAncestor(adw.Dialog.getGObjectType()) != null;
    }

    fn sidebarShown(split: *adw.OverlaySplitView, _: *gobject.ParamSpec, a: *App) callconv(.c) void {
        const shown = split.getShowSidebar() != 0;
        if (shown) a.card.removeCssClass("alone") else a.card.addCssClass("alone");
        a.cornerChanged();
    }

    /// Tells the panes how much of their top-left the corner covers.
    fn cornerChanged(a: *App) void {
        @import("../ui/workspace.zig").corner_right = a.cornerRight();
        a.tabsRoom();
        if (a.workspace) |ws| ws.cornerChanged();
        // The sidebar slides in or out over a few frames; the title follows it on each one.
        a.corner_until = glib.getMonotonicTime() + 600_000;
        if (a.corner_tick == 0) a.corner_tick = a.window.as(gtk.Widget).addTickCallback(&cornerTick, a, null);
    }

    /// Tabs above the panes start after the window's corner when it covers them, and so does
    /// the agent board's heading when there are no tabs above it.
    fn tabsRoom(a: *App) void {
        const strip = a.tab_strip.as(gtk.Widget);
        // Measured from the card the strip sits in, never from the strip itself: its own
        // place moves with the very margin being set, and measuring that fed each answer
        // into the next until the window was too wide for the screen to draw.
        var x: f64 = 0;
        var y: f64 = 0;
        const root = a.card.getRoot() orelse return;
        if (a.card.translateCoordinates(root.as(gtk.Widget), 0, 0, &x, &y) == 0) return;
        // While the sidebar slides away the card's place is a frame behind, which would leave
        // the heading under the corner for a moment; with the sidebar hidden the room it will
        // need in the end is known, and it gets at least that from the start.
        const settled: f64 = if (a.split.getShowSidebar() == 0) a.cornerRight() + 4 else 0;
        const room: c_int = @intFromFloat(@round(std.math.clamp(@max(settled, a.cornerRight() + 4 - x), 0, 400)));
        const tabs_above = strip.getVisible() != 0;
        const want: c_int = if (tabs_above) room else 0;
        if (strip.getMarginStart() != want) strip.setMarginStart(want);
        a.board.setInset(if (tabs_above) 0 else room);
    }

    /// Where the corner's buttons end, in window coordinates.
    fn cornerRight(a: *App) f64 {
        if (a.bare) return 0;
        const width: f64 = @floatFromInt(a.corner.getWidth());
        const root = a.corner.getRoot() orelse return width;
        var x: f64 = 0;
        var y: f64 = 0;
        if (a.corner.translateCoordinates(root.as(gtk.Widget), width, 0, &x, &y) == 0) return width;
        return x;
    }

    fn cornerTick(_: *gtk.Widget, _: *gdk.FrameClock, data: ?*anyopaque) callconv(.c) c_int {
        const a: *App = @ptrCast(@alignCast(data.?));
        @import("../ui/workspace.zig").corner_right = a.cornerRight();
        a.tabsRoom();
        if (a.workspace) |ws| ws.cornerChanged();
        // The sidebar's own slide from under the panes follows the split view's on each frame.
        if (sidebar_slide.from_under) a.side_slide.queueAllocate();
        if (glib.getMonotonicTime() < a.corner_until) return 1;
        a.corner_tick = 0;
        return 0;
    }

    fn connectPage(a: *App) *gtk.Widget {
        const page = adw.StatusPage.new();

        page.setTitle("Connect to Rex");
        page.setDescription("Enter a Rex address, such as user@box, ssh://user@box:2222 or http://my-mac:8765. SSH needs a trusted host key and an unlocked key or agent.");
        const box = gtk.Box.new(.vertical, 12);
        box.as(gtk.Widget).addCssClass("connect-box");
        box.as(gtk.Widget).setHalign(.center);
        a.entry = gtk.Entry.new();
        a.entry.setPlaceholderText("user@box or http://host:port");
        a.entry.as(gtk.Widget).setSizeRequest(360, -1);
        _ = gtk.Entry.signals.activate.connect(a.entry, *App, &connectClicked, a, .{});
        const button = gtk.Button.newWithLabel("Connect");
        button.as(gtk.Widget).addCssClass("suggested-action");
        button.as(gtk.Widget).addCssClass("pill");
        button.as(gtk.Widget).setHalign(.center);
        _ = gtk.Button.signals.clicked.connect(button, *App, &connectButton, a, .{});
        box.append(a.entry.as(gtk.Widget));
        box.append(button.as(gtk.Widget));
        page.setChild(box.as(gtk.Widget));
        return page.as(gtk.Widget);
    }

    fn connectButton(_: *gtk.Button, a: *App) callconv(.c) void {
        connectClicked(a.entry, a);
    }

    fn connectClicked(entry: *gtk.Entry, a: *App) callconv(.c) void {
        const url = normalizeUrl(std.mem.span(entry.as(gtk.Editable).getText())) orelse return a.toast("Enter a Rex address or an SSH address such as user@box or ssh://user@box:2222");
        defer gpa.free(url);
        settings.addHost(settings.labelFor(url), url);
        if (a.addHost(settings.labelFor(url), url)) |h| a.selectHost(h);
    }

    /// Connects to another Rex server. Its sessions join the sidebar under its name.
    pub fn addHost(a: *App, label: []const u8, url: []const u8) ?*Host {
        if (a.hasHostUrl(url)) {
            for (a.hosts.items) |x| if (std.mem.eql(u8, x.server.url, std.mem.trimEnd(u8, url, "/"))) return x;
        }
        // Everything is made before any of it is wired up, so running out of memory part way
        // leaves nothing behind but the workspace's few widgets.
        a.hosts.ensureUnusedCapacity(gpa, 1) catch return null;
        const h = gpa.create(Host) catch return null;
        const host_label = gpa.dupe(u8, label) catch {
            gpa.destroy(h);
            return null;
        };
        const page = std.fmt.allocPrintSentinel(gpa, "host-{d}", .{a.next_page}, 0) catch {
            gpa.free(host_label);
            gpa.destroy(h);
            return null;
        };
        const s = Server.create(url, clientLabel()) catch {
            gpa.free(page);
            gpa.free(host_label);
            gpa.destroy(h);
            return null;
        };
        const ws = Workspace.create(s) catch {
            s.destroy();
            gpa.free(page);
            gpa.free(host_label);
            gpa.destroy(h);
            return null;
        };
        h.* = .{ .app = a, .label = host_label, .server = s, .workspace = ws, .page = page, .serial = a.next_page, .shot = gtk.WidgetPaintable.new(ws.root) };
        a.next_page += 1;
        s.observer = .{ .ctx = h, .changed = serverChanged };
        s.performer = .{ .ctx = h, .perform = perform };
        s.prompt_presenter = .{ .ctx = h, .show = showPrompt, .dismiss = dismissPrompt };
        _ = a.stack.addNamed(ws.root, h.page.ptr);
        a.hosts.appendAssumeCapacity(h);
        a.remoteOptionsChanged();
        if (a.current == null) a.selectHost(h);
        a.rebuildSidebar();
        return h;
    }

    /// Applies the two choices about remote hosts. Keys: each host's panes answer to their own
    /// Rex config, or, with "Use this computer's keys on remote hosts" on, to the config of
    /// the server on this computer. Colors: a remote host's panes take the theme picked here,
    /// or, with "Use each remote host's own colors" on, that host's.
    pub fn remoteOptionsChanged(a: *App) void {
        var here: ?*Server = null;
        if (settings.current.local_keys) for (a.hosts.items) |h| {
            if (here == null and !h.remote()) here = h.server;
        };
        var recolor = false;
        for (a.hosts.items) |h| {
            h.server.keys_from = if (here != null and here.? != h.server) here else null;
            const own = settings.current.remote_colors and h.remote();
            if (own == h.server.own_colors) continue;
            h.server.own_colors = own;
            recolor = true;
            var it = h.server.streams.valueIterator();
            while (it.next()) |st| st.*.hostColorsChanged();
        }
        if (recolor) {
            a.theme_for = null;
            a.applyTheme();
        }
    }

    pub fn removeHost(a: *App, h: *Host) void {
        for (a.hosts.items, 0..) |x, i| if (x == h) {
            _ = a.hosts.orderedRemove(i);
            break;
        };
        if (a.filter == h) a.filter = null;
        a.remoteOptionsChanged();
        // Nothing may still point at the host once it is freed: the activity panel's rows and
        // any open palette, Go to Anything or folder browser let go of it first.
        a.activity.hostRemoved();
        a.board.hostRemoved();
        @import("../ui/palette.zig").serverGone(h.server);
        @import("../ui/goto.zig").hostRemoved(h.server);
        @import("../ui/ports.zig").serverGone(h.server);
        // The workspace goes while its widget and the server are still there, since freeing it
        // releases its terminals; the widget leaves the stack after.
        // Calls still out fail as the server goes; none of them may reach the freed workspace.
        h.server.observer = null;
        h.server.performer = null;
        const root = h.workspace.root;
        a.overview.dropHost(h);
        h.shot.unref();
        h.workspace.destroy();
        a.stack.remove(root);
        h.server.destroy();
        if (a.current == h) {
            a.current = null;
            a.server = null;
            a.workspace = null;
            setSlot(&a.session_id, null);
            setSlot(&a.window_id, null);
            if (a.hosts.items.len > 0) a.selectHost(a.hosts.items[0]) else a.stack.setVisibleChildName("connect");
        }
        var muted = h.muted_tabs.keyIterator();
        while (muted.next()) |key| gpa.free(key.*);
        h.muted_tabs.deinit(gpa);
        gpa.free(h.label);
        gpa.free(h.page);
        gpa.destroy(h);
        a.awakeChanged();
        a.rebuildSidebar();
    }

    /// Shows a host's sessions in the content area.
    pub fn selectHost(a: *App, h: *Host) void {
        if (a.current == h) return;
        a.current = h;
        a.server = h.server;
        a.workspace = h.workspace;
        a.was_online = false;
        a.theme_for = null;
        setSlot(&a.session_id, null);
        setSlot(&a.window_id, null);
        a.applyTheme();
        a.showState();
        _ = a.ensureSelection();
    }

    /// Whether a pane's folder differs from the one last seen for it, which is then remembered.
    fn folderMoved(a: *App, h: *Host, block_id: []const u8, path: []const u8) bool {
        var hasher = std.hash.Wyhash.init(@intFromPtr(h));
        hasher.update(block_id);
        const key = hasher.final();
        const now = std.hash.Wyhash.hash(0, path);
        // Panes come and go; the few bytes each leaves are dropped together now and then.
        if (a.block_folders.count() > 4096) a.block_folders.clearRetainingCapacity();
        const slot = a.block_folders.getOrPut(gpa, key) catch return true;
        if (slot.found_existing and slot.value_ptr.* == now) return false;
        slot.value_ptr.* = now;
        return true;
    }

    fn refHost(h: *Host) HostRef {
        return .{ .host = h, .serial = h.serial };
    }

    /// The host a dialog was opened for, unless it has been removed since.
    fn liveHost(a: *App, ref: HostRef) ?*Host {
        for (a.hosts.items) |h| if (h == ref.host and h.serial == ref.serial) return h;
        return null;
    }

    fn hostOf(a: *App, s: *Server) ?*Host {
        for (a.hosts.items) |h| if (h.server == s) return h;
        return null;
    }

    // Following the server.

    /// Asks again whether each server could be updated, after the setting for it is switched.
    pub fn lookForUpdates(a: *App) void {
        for (a.hosts.items) |h| updates.check(h.server.rex_version);
    }

    /// Says once, for each release, that a server could be updated to it. A Mac's Rex updates
    /// itself, so only servers that get Rex from a package are spoken for.
    fn announceUpdate(a: *App) void {
        for (a.hosts.items) |h| {
            const s = h.server;
            const newer = updates.available(s.rex_version) orelse continue;
            const platform = s.platform orelse continue;
            if (std.mem.startsWith(u8, platform, "darwin")) continue;
            if (std.mem.eql(u8, settings.current.rex_update_told, newer)) continue;
            var buf: [256]u8 = undefined;
            s.notifyMessage(std.fmt.bufPrint(&buf, "Rex {s} is out. Update Rex on {s} with that computer's package manager.", .{ newer, h.label }) catch continue);
            settings.setString(&settings.current.rex_update_told, newer);
        }
    }

    fn serverChanged(ctx: *anyopaque, what: server_mod.Change, session_id: ?[]const u8) void {
        const h: *Host = @ptrCast(@alignCast(ctx));
        const a = h.app;
        const here = a.current == h;
        // Runs even for background hosts and a closed block's final notification.
        if (what == .block or what == .view or what == .sessions or what == .state) a.awakeChanged();
        switch (what) {
            .state => {
                if (here) {
                    a.applyTheme();
                    a.showState();
                }
                a.rebuildSidebar();
                a.announceUpdate();
            },
            .sessions => {
                if (here) _ = a.ensureSelection();
                a.rebuildSidebar();
                a.overview.changed();
            },
            .view => {
                // Picking a session shows it, so it isn't shown a second time below.
                const shown = if (here) a.ensureSelection() else false;
                a.rebuildSidebar();
                a.activity.changed();
                a.board.changed();
                a.overview.changed();
                a.updateEye();
                if (here) if (a.session_id) |sel| if (session_id) |sid| if (std.mem.eql(u8, sel, sid)) {
                    if (!shown) a.showSelected();
                    a.finishMinimize();
                    a.autobalance();
                };
            },
            .block => {
                const block = session_id orelse return;
                // What happens in the pane being looked at is seen as it happens.
                if (h.server.blockInfo(block)) |info| if (info.attention and a.lookingAt(h, block)) h.server.clearAttention(block);
                h.workspace.blockChanged(block);
                a.overview.blockChanged(h, block);
                a.refreshRows();
                a.activity.changed();
                a.board.changed();
                a.updateEye();
                a.updateBadge();
                if (h.server.blockInfo(block)) |info| if (info.folder) |f| {
                    var pbuf: [1024]u8 = undefined;
                    const path = folderPath(&pbuf, f);
                    // Block details change often; a folder is only recent when a pane moves to it.
                    if (path.len > 1 and a.folderMoved(h, block, path)) settings.addRecentPath(path);
                };
            },
            .alert => a.showAlert(h),
            .keymap => {},
            .hosts => a.importListedHosts(h),
            .bell => if (here) if (session_id) |b| if (h.workspace.paneOf(b)) |p| p.term.flash(),
            .clipboard => {
                const z = gpa.dupeSentinel(u8, h.server.clipboard_text.items, 0) catch return;
                defer gpa.free(z);
                a.window.as(gtk.Widget).getClipboard().setText(z.ptr);
            },
            .message => {
                const s = h.server;
                const text = gpa.dupeSentinel(u8, s.message.items, 0) catch return;
                defer gpa.free(text);
                a.toast(text);
            },
        }
    }

    /// Colors the whole window from the host's terminal theme, once it is known.
    pub fn applyTheme(a: *App) void {
        const colors = if (a.server) |s| s.windowColors() else themes.active;
        if (a.theme_css != null) {
            if (colors == null) return;
            if (a.theme_for) |old| if (std.meta.eql(old, colors.?)) return;
        }
        a.theme_for = colors;
        // A forced scheme that the theme doesn't match uses a plain palette of that brightness.
        var source = colors orelse @import("../rex/stream.zig").Colors{};
        const theme_dark = theme.Palette.from(source).dark;
        switch (settings.current.color_scheme) {
            .auto => {},
            .dark => if (!theme_dark) {
                source = .{};
            },
            .light => if (theme_dark) {
                source = .{ .bg = 0xFFF7F7F5, .fg = 0xFF2C2C2E, .cursor = 0xFF3366CC };
            },
        }
        const palette = theme.Palette.from(source);
        const cv = palette.canvas;
        termview.theme_bg = (@as(u32, @intFromFloat(@round(cv.r * 255))) << 16) | (@as(u32, @intFromFloat(@round(cv.g * 255))) << 8) | @as(u32, @intFromFloat(@round(cv.b * 255)));
        const ac = palette.accent;
        termview.cursor_accent = (@as(u32, @intFromFloat(@round(ac.r * 255))) << 16) | (@as(u32, @intFromFloat(@round(ac.g * 255))) << 8) | @as(u32, @intFromFloat(@round(ac.b * 255)));
        const ok = palette.success;
        termview.theme_green = (@as(u32, @intFromFloat(@round(ok.r * 255))) << 16) | (@as(u32, @intFromFloat(@round(ok.g * 255))) << 8) | @as(u32, @intFromFloat(@round(ok.b * 255)));
        a.redrawAll();
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        palette.css(&out.writer) catch return;
        out.writer.writeByte(0) catch return;
        const provider = a.theme_css orelse blk: {
            const p = gtk.CssProvider.new();
            gtk.StyleContext.addProviderForDisplay(gdk.Display.getDefault().?, p.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            a.theme_css = p;
            break :blk p;
        };
        provider.loadFromString(@ptrCast(out.written().ptr));
        adw.StyleManager.getDefault().setColorScheme(if (palette.dark) .force_dark else .force_light);
    }

    fn showState(a: *App) void {
        const s = a.server orelse return;
        switch (s.state) {
            .online => {
                if (a.current) |h| a.stack.setVisibleChildName(h.page.ptr);
                if (!a.was_online) if (a.workspace) |w| w.resendSizes();
                a.was_online = true;
            },
            .connecting => if (!a.was_online) {
                a.status.setIconName(null);
                // A connection is usually up before anyone could read a message, so the page
                // stays empty while it's made; a server that can't be reached says so after.
                a.status.setTitle("");
                a.status.setDescription(null);
                a.retry_button.as(gtk.Widget).setVisible(0);
                a.stack.setVisibleChildName("status");
            },
            .offline => {
                a.was_online = false;
                const reason = gpa.dupeSentinel(u8, s.reason.items, 0) catch return;
                defer gpa.free(reason);
                a.status.setIconName(null);
                a.status.setTitle("Can't reach Rex");
                a.status.setDescription(reason.ptr);
                a.retry_button.as(gtk.Widget).setVisible(1);
                a.stack.setVisibleChildName("status");
            },
        }
    }

    /// Picks a session and window to show when none is picked or the picked one went away.
    /// Returns whether it showed one.
    fn ensureSelection(a: *App) bool {
        const s = a.server orelse return false;
        // A window opened for one tab shows it as soon as its session is known.
        if (std.c.getenv("RENUX_OPEN")) |env| if (!open_done) {
            var parts = std.mem.splitScalar(u8, std.mem.span(env), '\t');
            const url = parts.next() orelse "";
            const sid = parts.next() orelse "";
            const wid = parts.next() orelse "";
            if (std.mem.eql(u8, std.mem.trimEnd(u8, url, "/"), s.url)) if (s.sessionView(sid)) |v| if (v.window(wid) != null) {
                open_done = true;
                a.auto_picked = false;
                setSlot(&a.session_id, sid);
                setSlot(&a.window_id, wid);
                a.showSelected();
                return true;
            };
        };
        if (a.session_id) |sel| {
            var found = false;
            for (s.sessions.items) |session| if (std.mem.eql(u8, session.id, sel)) {
                found = true;
            };
            // A session the app chose itself gives way once another turns out to have windows.
            const empty = if (s.sessionView(sel)) |v| v.windows.len == 0 else true;
            if (found and !(a.auto_picked and empty and a.firstWithWindows(s) != null)) {
                if (s.sessionView(sel)) |v| {
                    if (a.window_id) |wid| if (v.window(wid) == null) setSlot(&a.window_id, null);
                }
                return false;
            }
            setSlot(&a.session_id, null);
            setSlot(&a.window_id, null);
        }
        if (s.sessions.items.len == 0) return false;
        setSlot(&a.session_id, a.firstWithWindows(s) orelse s.sessions.items[0].id);
        a.auto_picked = true;
        a.showSelected();
        return true;
    }

    fn firstWithWindows(_: *App, s: *Server) ?[]const u8 {
        for (s.sessions.items) |session| if (s.sessionView(session.id)) |v| {
            if (v.windows.len > 0) return session.id;
        };
        return null;
    }

    fn clientLabel() []const u8 {
        if (settings.current.client_label.len > 0) return settings.current.client_label;
        return std.mem.span(glib.getHostName());
    }

    fn showSelected(a: *App) void {
        const s = a.server orelse return;
        const ws = a.workspace orelse return;
        const sid = a.session_id orelse return;
        if (s.sessionView(sid) == null) return;
        const w = a.shownWindow();
        ws.show(sid, w);
        s.readyTerminals(sid, if (w) |shown| shown.id else null);
        a.selectSidebarRow();
        // The activity panel marks the rows of the tab on screen.
        a.activity.changed();
        a.rebuildTabs();
        // Panes have no place until they're laid out, so the corner's room is measured again,
        // and followed for a moment while they settle. Only another tab or another top-left pane
        // needs that; the many updates that change neither just check the room once.
        var top_left: []const u8 = "";
        for (ws.panes.items) |pane| if (!pane.floating and pane.rect.x < 0.001 and pane.rect.y < 0.001) {
            top_left = pane.block_id;
        };
        const corner_for = hashParts(&.{ sid, if (w) |win| win.id else "", top_left });
        if (corner_for != a.corner_for) {
            a.corner_for = corner_for;
            a.cornerChanged();
        } else {
            a.tabsRoom();
            ws.cornerChanged();
        }
    }

    /// Brings the tabs above the panes up to date before the next frame, however often it's asked.
    fn rebuildTabs(a: *App) void {
        a.tabs_stale = true;
        a.queueRefresh();
    }

    /// Brings the sidebar, and with it the tabs, up to date before the next frame, however often
    /// it's asked: one change on a server asks several times over.
    pub fn rebuildSidebar(a: *App) void {
        a.sidebar_stale = true;
        // Rows of a host that was just removed can't wait: they point at it.
        for (a.rows.items) |r| if (r) |row| {
            if (std.mem.indexOfScalar(*Host, a.hosts.items, row.host) == null) return a.refreshNow();
        };
        a.queueRefresh();
    }

    fn queueRefresh(a: *App) void {
        // Ahead of GTK's layout and drawing, so the frame that shows a change shows all of it.
        if (a.refresh_idle == 0) a.refresh_idle = glib.idleAddFull(glib.PRIORITY_HIGH_IDLE, &refreshIdle, a, null);
    }

    fn refreshIdle(data: ?*anyopaque) callconv(.c) c_int {
        const a: *App = @ptrCast(@alignCast(data.?));
        a.refresh_idle = 0;
        a.refreshNow();
        return 0;
    }

    fn refreshNow(a: *App) void {
        if (a.refresh_idle != 0) {
            _ = glib.Source.remove(a.refresh_idle);
            a.refresh_idle = 0;
        }
        const sidebar = a.sidebar_stale;
        const tabs = a.tabs_stale or sidebar;
        a.sidebar_stale = false;
        a.tabs_stale = false;
        if (sidebar) a.syncSidebar();
        if (tabs) a.syncTabs();
    }

    /// A tab's name: every program in its window, or its focused pane's, as the setting says.
    fn tabTitle(h: *Host, buf: []u8, w: *const view.Window, v: *const view.SessionView) [:0]const u8 {
        return if (settings.current.tab_processes) processList(h, buf, w) else rowTitle(h, buf, w, v);
    }

    /// The tabs above the panes: one per window of the shown session, then a new-tab button.
    /// Tabs that are already there keep their buttons and only show what changed.
    fn syncTabs(a: *App) void {
        const strip = a.tab_strip.as(gtk.Widget);
        const above = settings.current.tab_position == .above;
        const h = a.current;
        const sid = a.session_id;
        const v = if (h) |host| if (sid) |id| host.server.sessionView(id) else null else null;
        if (!above or v == null) {
            while (strip.getFirstChild()) |c| a.tab_strip.remove(c);
            a.tab_marks.clearRetainingCapacity();
            a.tabs_key = 0;
            strip.setVisible(@intFromBool(above));
            return;
        }
        strip.setVisible(1);
        const host = h.?;
        const session_view = v.?;
        const shown = a.shownWindow();
        // The strip as a whole: the host and session its buttons name, and how wide tabs are.
        const tabs_key = hashParts(&.{ host.page, sid.?, if (settings.current.tab_fill) "fill" else "fixed" });
        var same = tabs_key == a.tabs_key and a.tab_marks.items.len == session_view.windows.len;
        if (same) for (session_view.windows, a.tab_marks.items) |*w, mark| {
            if (mark.key != hashParts(&.{w.id})) same = false;
        };
        if (same) {
            for (session_view.windows, a.tab_marks.items) |*w, *mark| {
                const button = mark.button orelse continue;
                if (shown == w) button.addCssClass("active") else button.removeCssClass("active");
                var tbuf: [256]u8 = undefined;
                const title = tabTitle(host, &tbuf, w, session_view);
                if (mark.label) |l| if (!std.mem.eql(u8, std.mem.span(l.getText()), title)) l.setText(title.ptr);
                a.updateTile(mark, host.server, w);
            }
            return;
        }
        while (strip.getFirstChild()) |c| a.tab_strip.remove(c);
        a.tab_marks.clearRetainingCapacity();
        a.tabs_key = tabs_key;
        for (session_view.windows) |*w| {
            const tab = gtk.Button.new();
            tab.as(gtk.Widget).addCssClass("tab");
            tab.as(gtk.Widget).addCssClass("flat");
            if (shown == w) tab.as(gtk.Widget).addCssClass("active");
            const line = gtk.Box.new(.horizontal, 7);
            const tile = rowTile(host.server, w);
            line.append(tile);
            var tbuf: [256]u8 = undefined;
            const title = tabTitle(host, &tbuf, w, session_view);
            const label = gtk.Label.new(title.ptr);
            label.setEllipsize(.end);
            label.setXalign(0);
            label.as(gtk.Widget).setHexpand(1);
            line.append(label.as(gtk.Widget));
            var abuf: [600]u8 = undefined;
            // A tab that can't be named is left out, and the marks then differ from the windows,
            // so the next change builds the strip again.
            const ids = std.fmt.bufPrintSentinel(&abuf, "{s} {s}", .{ sid.?, w.id }, 0) catch continue;
            const close = icons.button(.close, "Close tab", "app.close-window");
            close.as(gtk.Actionable).setActionTargetValue(glib.Variant.newString(ids.ptr));
            close.as(gtk.Widget).addCssClass("tab-close");
            line.append(close.as(gtk.Widget));
            tab.setChild(line.as(gtk.Widget));
            tab.as(gtk.Actionable).setActionName("app.show-window");
            tab.as(gtk.Actionable).setActionTargetValue(glib.Variant.newString(ids.ptr));
            if (settings.current.tab_fill) tab.as(gtk.Widget).setHexpand(1) else tab.as(gtk.Widget).setSizeRequest(180, -1);
            a.tab_marks.append(gpa, .{ .key = hashParts(&.{w.id}), .label = label, .line = line, .tile = tile, .tile_for = tileFor(w), .button = tab.as(gtk.Widget) }) catch continue;
            a.tab_strip.append(tab.as(gtk.Widget));
        }
        const add = icons.button(.plus, "New tab", "app.new-window");
        add.as(gtk.Widget).addCssClass("tab-new");
        a.tab_strip.append(add.as(gtk.Widget));
    }

    /// Gives a row or tab a new tile when its window's panes are no longer the ones it draws.
    fn updateTile(_: *App, mark: *RowMark, s: *Server, w: *const view.Window) void {
        const line = mark.line orelse return;
        const now = tileFor(w);
        if (mark.tile) |old| {
            if (mark.tile_for == now) return old.queueDraw();
            line.remove(old);
        }
        const tile = rowTile(s, w);
        line.prepend(tile);
        mark.tile = tile;
        mark.tile_for = now;
    }

    /// Every program in a window, such as "zsh · nvim · claude", for tabs that show them all.
    fn processList(h: *Host, buf: []u8, w: *const view.Window) [:0]const u8 {
        var n: usize = 0;
        for (w.layers) |l| for (l.blocks) |b| {
            const info = h.server.blockInfo(b.id) orelse continue;
            const prog = (if (info.has_status) info.status_app else null) orelse info.program orelse continue;
            const name = programName(prog);
            const sep: []const u8 = if (n > 0) " · " else "";
            if (n + sep.len + name.len + 1 >= buf.len) break;
            @memcpy(buf[n .. n + sep.len], sep);
            n += sep.len;
            @memcpy(buf[n .. n + name.len], name);
            n += name.len;
        };
        if (n == 0) return std.fmt.bufPrintSentinel(buf, "Window", .{}, 0) catch "";
        buf[n] = 0;
        return buf[0..n :0];
    }

    fn showWindowAction(a: *App, session_id: []const u8, window_id: []const u8) void {
        a.showBoard(false);
        a.openTab(a.current orelse return, session_id, window_id);
        if (a.workspace) |w| w.grabFocus();
    }

    /// Applies where tabs go: the sidebar's side, and the strip above the panes.
    pub fn tabsChanged(a: *App) void {
        const pos = settings.current.tab_position;
        a.split.setSidebarPosition(if (pos == .right) .end else .start);
        a.sidebar_handle.setHalign(if (pos == .right) .start else .end);
        a.header_room.setVisible(@intFromBool(pos != .right));
        const w = a.window.as(gtk.Widget);
        if (pos == .right) w.addCssClass("sidebar-end") else w.removeCssClass("sidebar-end");
        if (pos == .above) w.addCssClass("tabs-above") else w.removeCssClass("tabs-above");
        a.rebuildSidebar();
        a.rebuildTabs();
        a.setSidebarWidth(settings.current.sidebar_width);
    }

    /// The rows the sidebar should have now, in order: each host's name when several are shown,
    /// then its sessions, each followed by its windows unless they are folded away or shown as
    /// tabs above the panes.
    fn planSidebar(a: *App, plan: *std.ArrayList(RowPlan)) void {
        if (a.agents_only) return a.planAgents(plan);
        const several = a.hosts.items.len > 1 and a.filter == null;
        const above = settings.current.tab_position == .above;
        for (a.hosts.items) |h| {
            if (a.filter) |f| if (f != h) continue;
            if (several) plan.append(gpa, .{ .kind = .host, .host = h, .key = hashParts(&.{ "host", h.page }) }) catch return;
            const s = h.server;
            for (s.sessions.items) |*session| {
                const collapsed = a.collapsed.contains(session.id);
                plan.append(gpa, .{
                    .kind = .session,
                    .host = h,
                    .session = session,
                    .collapsed = collapsed,
                    .key = hashParts(&.{ "session", h.page, session.id, if (collapsed) "folded" else "open", if (above) "above" else "beside" }),
                }) catch return;
                if (above or collapsed) continue;
                const v = s.sessionView(session.id) orelse continue;
                for (v.windows) |*w| plan.append(gpa, .{
                    .kind = .window,
                    .host = h,
                    .session = session,
                    .view = v,
                    .window = w,
                    .key = hashParts(&.{ "window", h.page, session.id, w.id }),
                }) catch return;
            }
        }
    }

    /// The sidebar with the eye on: only agents, each on a row of its own with its status,
    /// under the session it runs in. Sessions without an agent are left out.
    fn planAgents(a: *App, plan: *std.ArrayList(RowPlan)) void {
        const several = a.hosts.items.len > 1 and a.filter == null;
        for (a.hosts.items) |h| {
            if (a.filter) |f| if (f != h) continue;
            if (several) plan.append(gpa, .{ .kind = .host, .host = h, .key = hashParts(&.{ "host", h.page }) }) catch return;
            const s = h.server;
            for (s.sessions.items) |*session| {
                const v = s.sessionView(session.id) orelse continue;
                var headed = false;
                for (v.windows) |*w| for (w.layers) |l| for (l.blocks) |blk| {
                    if (!blk.isTerminal()) continue;
                    const info = s.blockInfo(blk.id) orelse continue;
                    if (!info.has_status and !programs.isAgent(info.program)) continue;
                    if (!headed) {
                        headed = true;
                        plan.append(gpa, .{ .kind = .session, .host = h, .session = session, .key = hashParts(&.{ "session", h.page, session.id, "agents" }) }) catch return;
                    }
                    plan.append(gpa, .{ .kind = .agent, .host = h, .session = session, .view = v, .window = w, .block_id = blk.id, .key = hashParts(&.{ "agent", h.page, session.id, blk.id }) }) catch return;
                };
            }
        }
    }

    /// What a pane's program says it is working on, or failing that the title it gave its
    /// terminal. A shell's title is only its folder, so a shell has none.
    pub fn taskOf(info: *const server_mod.BlockInfo) ?[]const u8 {
        if (info.has_status) if (info.task) |t| if (t.len > 0) return t;
        const prog = (if (info.has_status) info.status_app else null) orelse info.program;
        const is_shell = if (prog) |p| termview.TermView.isShell(programs.programName(p)) else true;
        if (!is_shell) if (info.title) |t| if (t.len > 0) return t;
        return null;
    }

    /// Writes an agent row's text from what its pane reports now.
    fn fillAgent(mark: *RowMark, h: *Host, block_id: []const u8) void {
        const info = h.server.blockInfo(block_id);
        var buf: [320]u8 = undefined;
        var zbuf: [321]u8 = undefined;
        const prog: ?[]const u8 = if (info) |i| ((if (i.has_status) i.status_app else null) orelse i.program) else null;
        const name = (if (info) |i| taskOf(i) else null) orelse programs.displayTitle(&buf, prog, null);
        const n = @min(name.len, zbuf.len - 1);
        @memcpy(zbuf[0..n], name[0..n]);
        zbuf[n] = 0;
        setLabel(mark.label, zbuf[0..n :0]);
        const status = if (info) |i| (if (i.has_status) i.status else .other) else .other;
        if (mark.sub) |sub| {
            setLabel(sub, switch (status) {
                .working => "Working",
                .blocked => "Needs you",
                .failed => "Failed",
                .done => "Done",
                .other => "Idle",
            });
            inline for (.{ "blocked", "failed" }, .{ server_mod.StatusKind.blocked, server_mod.StatusKind.failed }) |class, kind| {
                if (status == kind) sub.as(gtk.Widget).addCssClass(class) else sub.as(gtk.Widget).removeCssClass(class);
            }
        }
        var tbuf: [32]u8 = undefined;
        setLabel(mark.when, if (status == .other) "" else @import("../ui/board.zig").ago(&tbuf, if (info) |i| i.since else 0));
        // The tile carries the program and its status dot; it is made again when either changes.
        var hasher = std.hash.Wyhash.init(1);
        hasher.update(prog orelse "");
        hasher.update(std.mem.asBytes(&status));
        if (info) |i| hasher.update(std.mem.asBytes(&i.attention));
        const key = hasher.final() | 1;
        if (key != mark.tile_for) if (mark.line) |line| {
            mark.tile_for = key;
            if (mark.tile) |old| line.remove(old);
            const tile = @import("../icons/blockicon.zig").create(h.server, block_id, 20);
            tile.setValign(.center);
            line.prepend(tile);
            mark.tile = tile;
        };
    }

    /// Makes the sidebar show what the servers have now. While the same rows are wanted in the
    /// same order, which is nearly always, each is updated where it is; only when rows come, go
    /// or move is the list built again.
    fn syncSidebar(a: *App) void {
        var plan: std.ArrayList(RowPlan) = .empty;
        defer plan.deinit(gpa);
        a.planSidebar(&plan);
        a.rebuildFilterMenu();
        var same = plan.items.len == a.row_marks.items.len and a.rows.items.len == a.row_marks.items.len;
        if (same) for (plan.items, a.row_marks.items) |want, have| {
            if (want.key != have.key) same = false;
        };
        if (same) {
            for (plan.items, a.row_marks.items, a.rows.items) |want, *mark, *row| a.updateRow(want, mark, row);
        } else {
            a.rebuilding = true;
            defer a.rebuilding = false;
            // A session dropped in a new place arrives here in its new order; one still being
            // dragged loses its rows, and the drag ends.
            reorder.rebuilt();
            a.sidebar.removeAll();
            for (a.rows.items) |r| if (r) |row| {
                gpa.free(row.session_id);
                gpa.free(row.window_id);
                if (row.block_id.len > 0) gpa.free(row.block_id);
            };
            a.rows.clearRetainingCapacity();
            a.row_marks.clearRetainingCapacity();
            for (plan.items) |want| a.buildRow(want);
        }
        a.selectSidebarRow();
    }

    /// A host's name, with how its connection is doing when it isn't connected.
    fn hostHeading(buf: []u8, h: *Host) [:0]const u8 {
        return (switch (h.server.state) {
            .online => std.fmt.bufPrintSentinel(buf, "{s}", .{h.label}, 0),
            .connecting => std.fmt.bufPrintSentinel(buf, "{s} · connecting", .{h.label}, 0),
            .offline => std.fmt.bufPrintSentinel(buf, "{s} · offline", .{h.label}, 0),
        }) catch "";
    }

    fn sessionHeading(buf: []u8, session: *const server_mod.Session) [:0]const u8 {
        return std.fmt.bufPrintSentinel(buf, "{s}", .{if (session.label.len > 0) session.label else "Session"}, 0) catch "Session";
    }

    fn setLabel(label: ?*gtk.Label, text: [:0]const u8) void {
        const l = label orelse return;
        if (!std.mem.eql(u8, std.mem.span(l.getText()), text)) l.setText(text.ptr);
    }

    /// Shows what changed in a row that stays: its name, and its tile when its panes changed.
    fn updateRow(a: *App, want: RowPlan, mark: *RowMark, row: *?Row) void {
        var buf: [256]u8 = undefined;
        switch (want.kind) {
            .host => setLabel(mark.label, hostHeading(&buf, want.host)),
            .session => setLabel(mark.label, sessionHeading(&buf, want.session.?)),
            .agent => {
                fillAgent(mark, want.host, want.block_id);
                if (row.*) |*r| r.tile = mark.tile;
            },
            .window => {
                setLabel(mark.label, rowTitle(want.host, &buf, want.window.?, want.view.?));
                a.updateTile(mark, want.host.server, want.window.?);
                // `rows` holds the tile too, for `refreshRows`.
                if (row.*) |*r| r.tile = mark.tile;
            },
        }
    }

    /// Adds one row to the end of the sidebar, with its entry in `rows` and `row_marks`.
    fn buildRow(a: *App, want: RowPlan) void {
        const h = want.host;
        // Both lists get an entry for every row, so a row's index finds its entries.
        a.rows.ensureUnusedCapacity(gpa, 1) catch return;
        a.row_marks.ensureUnusedCapacity(gpa, 1) catch return;
        var buf: [256]u8 = undefined;
        switch (want.kind) {
            .host => {
                const label = gtk.Label.new(hostHeading(&buf, h).ptr);
                label.setXalign(0);
                label.setEllipsize(.end);
                label.as(gtk.Widget).addCssClass("host-heading");
                const row = gtk.ListBoxRow.new();
                row.setChild(label.as(gtk.Widget));
                row.setActivatable(0);
                row.setSelectable(0);
                row.as(gtk.Widget).addCssClass("host-row");
                a.sidebar.append(row.as(gtk.Widget));
                a.rows.appendAssumeCapacity(null);
                a.row_marks.appendAssumeCapacity(.{ .key = want.key, .label = label });
            },
            .session => {
                const session = want.session.?;
                const above = settings.current.tab_position == .above;
                const sid_z = gpa.dupeSentinel(u8, session.id, 0) catch return;
                defer gpa.free(sid_z);
                // Tabs above the panes hold the windows; the sidebar picks the session.
                const picked: ?Row = if (above) pick: {
                    const session_id = gpa.dupe(u8, session.id) catch return;
                    break :pick .{ .host = h, .session_id = session_id, .window_id = &.{} };
                } else null;
                const label = gtk.Label.new(sessionHeading(&buf, session).ptr);
                label.setXalign(0);
                label.setEllipsize(.end);
                label.as(gtk.Widget).setHexpand(1);
                label.as(gtk.Widget).addCssClass("session-heading");
                const head = gtk.Box.new(.horizontal, 0);
                const tools = sidebar_tools.new();
                head.append(tools.as(gtk.Widget));
                tools.append(label.as(gtk.Widget));
                // On hover, like Rex: a new window in this session, and folding its windows away.
                const add = icons.button(.plus, "New window here", "app.new-window-in");
                add.as(gtk.Actionable).setActionTargetValue(glib.Variant.newString(sid_z.ptr));
                add.as(gtk.Widget).addCssClass("session-tool");
                tools.append(add.as(gtk.Widget));
                const fold = icons.button(if (want.collapsed) .right else .down, if (want.collapsed) "Show windows" else "Hide windows", "app.toggle-session");
                fold.as(gtk.Actionable).setActionTargetValue(glib.Variant.newString(sid_z.ptr));
                fold.as(gtk.Widget).addCssClass("session-tool");
                if (want.collapsed) fold.as(gtk.Widget).addCssClass("folded");
                fold.as(gtk.Widget).setVisible(@intFromBool(!above));
                tools.append(fold.as(gtk.Widget));
                const session_more = menuButton(sessionMenu(session.id), "Session");
                session_more.as(gtk.Widget).addCssClass("session-tool");
                head.append(session_more.as(gtk.Widget));
                const head_row = gtk.ListBoxRow.new();
                head_row.setChild(head.as(gtk.Widget));
                head_row.setActivatable(@intFromBool(above));
                head_row.setSelectable(@intFromBool(above));
                head_row.as(gtk.Widget).addCssClass("session-row");
                if (above) head_row.as(gtk.Widget).addCssClass("session-pick");
                // Dragged by its heading, a session goes to another place among its host's.
                const drag = gtk.GestureDrag.new();
                _ = gtk.GestureDrag.signals.drag_begin.connect(drag, *App, &sessionDragBegin, a, .{});
                _ = gtk.GestureDrag.signals.drag_update.connect(drag, *App, &sessionDragUpdate, a, .{});
                _ = gtk.GestureDrag.signals.drag_end.connect(drag, *App, &sessionDragEnd, a, .{});
                _ = gtk.Gesture.signals.cancel.connect(drag.as(gtk.Gesture), *App, &sessionDragCancel, a, .{});
                head_row.as(gtk.Widget).addController(drag.as(gtk.EventController));
                a.sidebar.append(head_row.as(gtk.Widget));
                a.rows.appendAssumeCapacity(picked);
                a.row_marks.appendAssumeCapacity(.{ .key = want.key, .label = label });
            },
            .agent => {
                const session_id = gpa.dupe(u8, want.session.?.id) catch return;
                const window_id = gpa.dupe(u8, want.window.?.id) catch return gpa.free(session_id);
                const block_id = gpa.dupe(u8, want.block_id) catch {
                    gpa.free(session_id);
                    return gpa.free(window_id);
                };
                const title = gtk.Label.new("");
                title.setXalign(0);
                title.setEllipsize(.end);
                title.as(gtk.Widget).addCssClass("row-title");
                const sub = gtk.Label.new("");
                sub.setXalign(0);
                sub.as(gtk.Widget).setHexpand(1);
                sub.as(gtk.Widget).addCssClass("agent-status");
                const when = gtk.Label.new("");
                when.as(gtk.Widget).addCssClass("agent-status");
                const foot = gtk.Box.new(.horizontal, 6);
                foot.append(sub.as(gtk.Widget));
                foot.append(when.as(gtk.Widget));
                const text = gtk.Box.new(.vertical, 0);
                text.as(gtk.Widget).setHexpand(1);
                text.as(gtk.Widget).setValign(.center);
                text.append(title.as(gtk.Widget));
                text.append(foot.as(gtk.Widget));
                const line = gtk.Box.new(.horizontal, 8);
                line.append(text.as(gtk.Widget));
                const row = gtk.ListBoxRow.new();
                row.as(gtk.Widget).addCssClass("agent-row");
                row.setChild(line.as(gtk.Widget));
                a.sidebar.append(row.as(gtk.Widget));
                var mark: RowMark = .{ .key = want.key, .label = title, .line = line, .sub = sub, .when = when };
                fillAgent(&mark, h, want.block_id);
                a.rows.appendAssumeCapacity(.{ .host = h, .session_id = session_id, .window_id = window_id, .block_id = block_id, .label = title, .line = line, .tile = mark.tile });
                a.row_marks.appendAssumeCapacity(mark);
            },
            .window => {
                const session = want.session.?;
                const w = want.window.?;
                const session_id = gpa.dupe(u8, session.id) catch return;
                const window_id = gpa.dupe(u8, w.id) catch return gpa.free(session_id);
                const item = gtk.Label.new(rowTitle(h, &buf, w, want.view.?).ptr);
                item.setXalign(0);
                item.setEllipsize(.end);
                item.as(gtk.Widget).addCssClass("row-title");
                item.as(gtk.Widget).setHexpand(1);
                const line = gtk.Box.new(.horizontal, 8);
                const tile = rowTile(h.server, w);
                line.append(tile);
                line.append(item.as(gtk.Widget));
                const more = menuButton(windowMenu(session.id, w.id), "Window");
                more.as(gtk.Widget).addCssClass("row-more");
                // Its hover highlight keeps clear of the row's own edge, above, below and beside.
                more.as(gtk.Widget).setValign(.center);
                line.append(more.as(gtk.Widget));
                const row = gtk.ListBoxRow.new();
                row.setChild(line.as(gtk.Widget));
                @import("../ui/hovercard.zig").attach(row.as(gtk.Widget), item, more, h.server, session.id, w.id);
                a.sidebar.append(row.as(gtk.Widget));
                a.rows.appendAssumeCapacity(.{ .host = h, .session_id = session_id, .window_id = window_id, .label = item, .line = line, .tile = tile });
                a.row_marks.appendAssumeCapacity(.{ .key = want.key, .label = item, .line = line, .tile = tile, .tile_for = tileFor(w) });
            },
        }
    }

    fn rebuildFilterMenu(a: *App) void {
        a.filter_menu.removeAll();
        const all = gio.MenuItem.new(if (a.filter == null) "All hosts  ✓" else "All hosts", null);
        all.setActionAndTargetValue("app.filter", glib.Variant.newString(""));
        a.filter_menu.appendItem(all);
        for (a.hosts.items) |h| {
            var buf: [160]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&buf, "{s}{s}", .{ h.label, if (a.filter == h) "  ✓" else "" }, 0) catch continue;
            const item = gio.MenuItem.new(text.ptr, null);
            item.setActionAndTargetValue("app.filter", glib.Variant.newString(h.page.ptr));
            a.filter_menu.appendItem(item);
        }
        // Always just the icon: lit while the sidebar is narrowed to a host, whose name the
        // tooltip gives, and plain otherwise.
        if (a.filter) |f| {
            var tip: [160]u8 = undefined;
            if (std.fmt.bufPrintSentinel(&tip, "Showing only {s}", .{f.label}, 0)) |z| a.filter_button.as(gtk.Widget).setTooltipText(z.ptr) else |_| {}
            a.filter_button.as(gtk.Widget).addCssClass("filtered");
        } else {
            a.filter_button.as(gtk.Widget).setTooltipText("Show one host or all of them");
            a.filter_button.as(gtk.Widget).removeCssClass("filtered");
        }
    }

    fn filterAction(a: *App, page_name: []const u8) void {
        a.filter = null;
        for (a.hosts.items) |h| if (std.mem.eql(u8, h.page, page_name)) {
            a.filter = h;
            a.selectHost(h);
        };
        a.rebuildSidebar();
    }

    /// Adds the hosts a server listed that Renux doesn't have yet.
    pub fn importListedHosts(a: *App, h: *Host) void {
        var added: usize = 0;
        for (h.server.listed_hosts) |lh| {
            if (a.hasHostUrl(lh.url)) continue;
            settings.addHost(lh.label, lh.url);
            _ = a.addHost(lh.label, lh.url);
            added += 1;
        }
        var buf: [96]u8 = undefined;
        const text = if (added == 0)
            std.fmt.bufPrintSentinel(&buf, "No new hosts on {s}", .{h.label}, 0) catch return
        else
            std.fmt.bufPrintSentinel(&buf, "Added {d} host{s} from {s}", .{ added, if (added == 1) "" else "s", h.label }, 0) catch return;
        a.toast(text);
    }

    pub fn hasHostUrl(a: *App, url: []const u8) bool {
        const want = std.mem.trimEnd(u8, url, "/");
        for (a.hosts.items) |x| if (std.mem.eql(u8, x.server.url, want)) return true;
        return false;
    }

    /// Asks for a Rex server's address, saves it, and connects. Rex devices on this computer's
    /// tailnet are offered with one click, and an address on the clipboard is filled in.
    fn addHostDialog(a: *App) void {
        const dialog = adw.AlertDialog.new("Add Remote Host", "An SSH address (user@box), or a Rex HTTP or HTTPS address");
        const box = gtk.Box.new(.vertical, 8);
        const url = gtk.Entry.new();
        url.setPlaceholderText("user@box or https://host");
        url.setActivatesDefault(1);
        const name = gtk.Entry.new();
        name.setPlaceholderText("Name (optional)");
        name.setActivatesDefault(1);
        box.append(url.as(gtk.Widget));
        box.append(name.as(gtk.Widget));
        // Asked without waiting: the list fills in when Tailscale answers.
        if (gpa.create(TailnetList)) |list| {
            list.* = .{ .app = a, .box = box, .url = url, .name = name };
            inline for (.{ box, url, name }) |w| _ = w.as(gobject.Object).ref();
            @import("../rex/tailscale.zig").read(list, &tailnetRead);
        } else |_| {}
        // An address copied from Rex's Pair screen is likely what's wanted.
        // The read can finish after the dialog closed, so it holds the field until then.
        _ = url.as(gobject.Object).ref();
        a.window.as(gtk.Widget).getClipboard().readTextAsync(null, &clipboardForUrl, url);
        dialog.setExtraChild(box.as(gtk.Widget));
        dialog.addResponse("cancel", "Cancel");
        dialog.addResponse("add", "Add");
        dialog.setResponseAppearance("add", .suggested);
        dialog.setDefaultResponse("add");
        const ctx = gpa.create(AddHostCtx) catch return;
        ctx.* = .{ .app = a, .url = url, .name = name };
        _ = adw.AlertDialog.signals.response.connect(dialog, *AddHostCtx, &hostAdded, ctx, .{});
        dialog.as(adw.Dialog).present(a.window.as(gtk.Widget));
    }

    const AddHostCtx = struct { app: *App, url: *gtk.Entry, name: *gtk.Entry };

    /// The Add Host dialog's fields, kept alive until Tailscale has answered.
    const TailnetList = struct { app: *App, box: *gtk.Box, url: *gtk.Entry, name: *gtk.Entry };

    fn tailnetRead(data: ?*anyopaque, ts: *@import("../rex/tailscale.zig").Status) void {
        const list: *TailnetList = @ptrCast(@alignCast(data.?));
        defer {
            inline for (.{ list.box, list.url, list.name }) |w| w.as(gobject.Object).unref();
            gpa.destroy(list);
        }
        var offered: usize = 0;
        for (ts.rex_hosts.items) |peer| {
            if (list.app.hasHostUrl(peer.url)) continue;
            if (offered == 0) {
                const heading = gtk.Label.new("On your tailnet");
                heading.setXalign(0);
                heading.as(gtk.Widget).addCssClass("dim-label");
                heading.as(gtk.Widget).setMarginTop(8);
                list.box.append(heading.as(gtk.Widget));
            }
            offered += 1;
            var buf: [256]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&buf, "{s}{s}", .{ peer.name, if (peer.online) "" else " (offline)" }, 0) catch continue;
            const b = gtk.Button.newWithLabel(text.ptr);
            b.as(gtk.Widget).addCssClass("flat");
            const pick_url = gpa.dupeSentinel(u8, peer.url, 0) catch continue;
            const pick_label = gpa.dupeSentinel(u8, peer.name, 0) catch {
                gpa.free(pick_url);
                continue;
            };
            const pick = gpa.create(TailnetPick) catch {
                gpa.free(pick_url);
                gpa.free(pick_label);
                continue;
            };
            pick.* = .{ .entry = list.url, .name = list.name, .url = pick_url, .label = pick_label };
            _ = gtk.Button.signals.clicked.connect(b, *TailnetPick, &tailnetPicked, pick, .{});
            // The pick belongs to its button and goes when the button does.
            gobject.Object.setDataFull(b.as(gobject.Object), "pick", pick, &TailnetPick.free);
            list.box.append(b.as(gtk.Widget));
        }
    }

    const TailnetPick = struct {
        entry: *gtk.Entry,
        name: *gtk.Entry,
        url: [:0]u8,
        label: [:0]u8,

        fn free(data: ?*anyopaque) callconv(.c) void {
            const p: *TailnetPick = @ptrCast(@alignCast(data orelse return));
            gpa.free(p.url);
            gpa.free(p.label);
            gpa.destroy(p);
        }
    };

    fn tailnetPicked(_: *gtk.Button, p: *TailnetPick) callconv(.c) void {
        p.entry.as(gtk.Editable).setText(p.url.ptr);
        p.name.as(gtk.Editable).setText(p.label.ptr);
    }

    fn clipboardForUrl(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const entry: *gtk.Entry = @ptrCast(@alignCast(data.?));
        defer entry.as(gobject.Object).unref();
        const clipboard: *gdk.Clipboard = @ptrCast(source orelse return);
        const text = clipboard.readTextFinish(result, null) orelse return;
        defer glib.free(text);
        const t = std.mem.span(text);
        if (!@import("../rex/tailscale.zig").looksLikeAddress(t)) return;
        if (std.mem.span(entry.as(gtk.Editable).getText()).len > 0) return;
        const trimmed = gpa.dupeSentinel(u8, std.mem.trim(u8, t, " \n\r\t"), 0) catch return;
        defer gpa.free(trimmed);
        entry.as(gtk.Editable).setText(trimmed.ptr);
    }

    fn hostAdded(_: *adw.AlertDialog, response: [*:0]const u8, ctx: *AddHostCtx) callconv(.c) void {
        defer gpa.destroy(ctx);
        if (!std.mem.eql(u8, std.mem.span(response), "add")) return;
        const url = normalizeUrl(std.mem.span(ctx.url.as(gtk.Editable).getText())) orelse return ctx.app.toast("Enter a Rex address or an SSH address such as user@box or ssh://user@box:2222");
        defer gpa.free(url);
        const typed = std.mem.trim(u8, std.mem.span(ctx.name.as(gtk.Editable).getText()), " ");
        const label = if (typed.len > 0) typed else settings.labelFor(url);
        settings.addHost(label, url);
        if (ctx.app.addHost(label, url)) |h| ctx.app.selectHost(h);
    }

    /// A window's row shows its explicit label, or the focused pane's title.
    pub fn rowTitle(h: *Host, buf: []u8, w: *const view.Window, v: *const view.SessionView) [:0]const u8 {
        if (w.title()) |t| return std.fmt.bufPrintSentinel(buf, "{s}", .{t}, 0) catch "Window";
        if (w.focused_block_id) |fb| for (h.workspace.panes.items) |p| if (std.mem.eql(u8, p.block_id, fb)) {
            var tb: [256]u8 = undefined;
            const t = p.term.title(&tb);
            return std.fmt.bufPrintSentinel(buf, "{s}", .{t}, 0) catch "Window";
        };
        const s = h.server;
        if (w.focused_block_id) |fb| if (s.blockInfo(fb)) |info| if (info.program) |prog| {
            var fbuf: [256]u8 = undefined;
            const name = programName(prog);
            if (info.folder) |f| return std.fmt.bufPrintSentinel(buf, "{s} {s}", .{ name, @import("../icons/programs.zig").shortFolder(&fbuf, f) }, 0) catch "Window";
            return std.fmt.bufPrintSentinel(buf, "{s}", .{name}, 0) catch "Window";
        };
        return windowTitle(buf, w, v);
    }

    /// Updates row titles and tiles in place, since block details change often.
    fn refreshRows(a: *App) void {
        // Agent rows are written from their panes, not their windows; the sidebar's own pass
        // updates them where they are.
        if (a.agents_only) return a.rebuildSidebar();
        for (a.rows.items) |r| if (r) |row| {
            const v = row.host.server.sessionView(row.session_id) orelse continue;
            const w = v.window(row.window_id) orelse continue;
            var buf: [256]u8 = undefined;
            if (row.label) |l| l.setText(rowTitle(row.host, &buf, w, v).ptr);
            if (row.tile) |t| t.queueDraw();
        };
    }

    fn showAlert(a: *App, h: *Host) void {
        const st = &settings.current;
        if (!st.alerts) return;
        const s = h.server;
        if (@import("small_actions.zig").muted(h, s.alert_block.items)) return;
        switch (s.alert_kind) {
            .blocked => if (!st.alert_blocked) return,
            .failed => if (!st.alert_error) return,
            .done => if (!st.alert_done) return,
            .notification => if (!st.terminal_notifications) return,
        }
        const active = a.window.as(gtk.Window).isActive() != 0;
        const shown = a.current == h and h.workspace.isShown(s.alert_block.items);
        // Someone looking at the pane already sees it.
        if (active and shown) return;
        const text = gpa.dupeSentinel(u8, s.alert_text.items, 0) catch return;
        defer gpa.free(text);
        // GLib's notifications go over the desktop's message bus, which a Mac doesn't have:
        // there the call only logs errors and shows nothing, so the Mac build keeps to the
        // sound, the Dock badge and the activity panel.
        if (builtin.os.tag != .macos) {
            const n = gio.Notification.new("Renux");
            defer n.as(gobject.Object).unref();
            n.setBody(text.ptr);
            var tbuf: [512]u8 = undefined;
            const where = std.fmt.bufPrintSentinel(&tbuf, "{s} {s} {s}", .{ h.page, s.alert_session.items, s.alert_block.items }, 0) catch return;
            n.setDefaultActionAndTargetValue("app.show-block", glib.Variant.newString(where.ptr));
            var ibuf: [128]u8 = undefined;
            const id = std.fmt.bufPrintSentinel(&ibuf, "block-{s}", .{s.alert_block.items}, 0) catch return;
            a.app.as(gio.Application).sendNotification(id.ptr, n);
        }
        if (st.sound) gdk.Display.getDefault().?.beep();
    }

    fn showBlockAction(a: *App, where: []const u8, block_id: []const u8) void {
        // `where` is "page session"; the action splits off the last part as the block.
        const space = std.mem.indexOfScalar(u8, where, ' ') orelse return;
        for (a.hosts.items) |h| if (std.mem.eql(u8, h.page, where[0..space])) a.selectHost(h);
        const session_id = where[space + 1 ..];
        const s = a.server orelse return;
        a.auto_picked = false;
        setSlot(&a.session_id, session_id);
        if (s.sessionView(session_id)) |v| if (v.windowOf(block_id)) |w| {
            setSlot(&a.window_id, w.id);
            s.focusWindow(session_id, w.id);
        };
        s.focusBlock(session_id, block_id);
        a.showSelected();
        a.rebuildSidebar();
        a.window.as(gtk.Window).present();
    }

    fn selectSidebarRow(a: *App) void {
        const want = a.shownRow();
        // The highlight is only touched when it has to move, so it never blinks.
        if (a.sidebar.getSelectedRow() == want) return;
        const was = a.rebuilding;
        a.rebuilding = true;
        defer a.rebuilding = was;
        // Nothing stays highlighted when the shown window has no row, such as an empty session.
        if (want) |row| a.sidebar.selectRow(row) else a.sidebar.unselectAll();
    }

    /// The sidebar row of the shown window, or of its session when tabs hold the windows.
    fn shownRow(a: *App) ?*gtk.ListBoxRow {
        const here = a.current orelse return null;
        const sid = a.session_id orelse return null;
        const shown = a.shownWindow() orelse return null;
        for (a.rows.items, 0..) |r, i| if (r) |row| {
            // With only agents listed, the row of the pane with the keyboard is the one lit.
            const here_block: []const u8 = if (a.workspace) |ws| (ws.focusedBlock() orelse "") else "";
            const matches = if (row.block_id.len > 0) std.mem.eql(u8, row.block_id, here_block) else if (row.window_id.len == 0) true else std.mem.eql(u8, row.window_id, shown.id);
            if (row.host == here and std.mem.eql(u8, row.session_id, sid) and matches) return a.sidebar.getRowAtIndex(@intCast(i));
        };
        return null;
    }

    pub fn openSession(a: *App, h: *Host, session_id: []const u8) void {
        a.selectHost(h);
        a.showSession(session_id);
    }

    pub fn openWindow(a: *App, h: *Host, session_id: []const u8, window_id: []const u8) void {
        a.selectHost(h);
        a.showWindowAction(session_id, window_id);
    }

    /// Puts a detached pane back, beside the focused pane of its session's shown tab.
    pub fn placeDetached(a: *App, h: *Host, session_id: []const u8, block_id: []const u8) void {
        a.selectHost(h);
        if (!eqlOpt(a.session_id, session_id)) a.showSession(session_id);
        const w = a.shownWindow() orelse return a.toast("Open a tab in that session first");
        const anchor = w.focused_block_id orelse (if (w.tiled()) |l| (if (l.blocks.len > 0) l.blocks[0].id else null) else null) orelse return a.toast("That tab has no pane to place it beside");
        h.server.moveBlock(session_id, block_id, anchor, true, false);
    }

    /// Shows the server's address as a QR code for Compy on a phone to scan.
    fn pairDevice(a: *App) bool {
        const s = a.server orelse return false;
        if (@import("../rex/ws.zig").unixPath(s.url) != null) {
            const url = gpa.dupeSentinel(u8, s.url, 0) catch return true;
            defer gpa.free(url);
            @import("pairing.zig").openLocal(a, url);
            return true;
        }
        @import("pairing.zig").open(a.window.as(gtk.Widget), s.url);
        return true;
    }

    var swipe_dx: f64 = 0;
    var swipe_dy: f64 = 0;
    var swipe_at: i64 = 0;
    var swipe_axis: enum { undecided, sideways, scrolling } = .undecided;
    var swipe_done = false;

    fn swiped(_: *gtk.EventControllerScroll, dx: f64, dy: f64, a: *App) callconv(.c) c_int {
        if (!settings.current.trackpad_gestures) return 0;
        // A pause means a new gesture, also when the trackpad never said the last one ended.
        const now = glib.getMonotonicTime();
        if (now - swipe_at > 250_000) swipeReset();
        swipe_at = now;
        // Each gesture is one thing or the other, decided by its first stretch: scrolling a
        // terminal up or down always drifts a little sideways, and must never count as a
        // swipe between tabs however long it goes on.
        if (swipe_axis == .undecided) {
            swipe_dx += dx;
            swipe_dy += dy;
            if (@abs(swipe_dx) + @abs(swipe_dy) < 16) return 0;
            swipe_axis = if (@abs(swipe_dx) > 2 * @abs(swipe_dy)) .sideways else .scrolling;
            return 0;
        }
        if (swipe_axis == .scrolling) return 0;
        swipe_dx += dx;
        // One tab for each swipe, once it has gone far enough.
        if (!swipe_done and @abs(swipe_dx) > 70) {
            swipe_done = true;
            _ = a.stepWindow(if (swipe_dx > 0) 1 else -1);
        }
        return 0;
    }

    fn swipeReset() void {
        swipe_dx = 0;
        swipe_dy = 0;
        swipe_done = false;
        swipe_axis = .undecided;
    }

    fn swipeEnded(_: *gtk.EventControllerScroll, _: *App) callconv(.c) void {
        swipeReset();
    }

    /// Hides the window, or brings it back to the front.
    pub fn toggleVisible(a: *App) void {
        const w = a.window.as(gtk.Widget);
        if (w.getVisible() != 0 and a.window.as(gtk.Window).isActive() != 0) w.setVisible(0) else a.window.as(gtk.Window).present();
    }

    fn toggleSignal(data: ?*anyopaque) callconv(.c) c_int {
        const a: *App = @ptrCast(@alignCast(data.?));
        a.toggleVisible();
        return 1;
    }

    fn sessionDragBegin(_: *gtk.GestureDrag, _: f64, y: f64, a: *App) callconv(.c) void {
        a.session_grab_y = y;
        a.session_dragging = false;
        a.session_drag_refused = false;
    }

    fn sessionDragUpdate(drag: *gtk.GestureDrag, _: f64, dy: f64, a: *App) callconv(.c) void {
        if (a.session_dragging) return reorder.update(dy);
        // A press that barely moves is a click, on the heading or one of its buttons.
        if (a.session_drag_refused or @abs(dy) < 6) return;
        const row = drag.as(gtk.EventController).getWidget() orelse return;
        if (!a.startSessionDrag(row)) {
            a.session_drag_refused = true;
            return;
        }
        a.session_dragging = true;
        _ = drag.as(gtk.Gesture).setState(.claimed);
        reorder.update(dy);
    }

    fn sessionDragEnd(_: *gtk.GestureDrag, _: f64, _: f64, a: *App) callconv(.c) void {
        if (!a.session_dragging) return;
        a.session_dragging = false;
        reorder.drop();
    }

    fn sessionDragCancel(_: *gtk.Gesture, _: ?*gdk.EventSequence, a: *App) callconv(.c) void {
        if (!a.session_dragging) return;
        a.session_dragging = false;
        reorder.cancel();
    }

    /// Lifts the session whose heading is `head` out of the sidebar, to be dragged among the
    /// other sessions of its host. False when there is nowhere to drag it to.
    fn startSessionDrag(a: *App, head: *gtk.Widget) bool {
        if (reorder.busy()) return false;
        if (a.sidebar_stale) a.refreshNow();
        var plan: std.ArrayList(RowPlan) = .empty;
        defer plan.deinit(gpa);
        a.planSidebar(&plan);
        // The plan is the sidebar's rows, one for one, while the two are in step.
        if (plan.items.len != a.row_marks.items.len) return false;
        for (plan.items, a.row_marks.items) |want, have| if (want.key != have.key) return false;
        const row = gobject.ext.cast(gtk.ListBoxRow, head) orelse return false;
        const index = row.getIndex();
        if (index < 0 or index >= plan.items.len) return false;
        const at: usize = @intCast(index);
        if (plan.items[at].kind != .session) return false;
        const h = plan.items[at].host;
        var groups: std.ArrayList(reorder.Group) = .empty;
        defer groups.deinit(gpa);
        a.clearDragIds();
        var dragged: usize = 0;
        for (plan.items, 0..) |want, i| {
            if (want.host != h) continue;
            switch (want.kind) {
                .host => {},
                .session => {
                    if (i == at) dragged = groups.items.len;
                    groups.append(gpa, .{ .first = i, .count = 1 }) catch return false;
                    a.drag_ids.append(gpa, gpa.dupe(u8, want.session.?.id) catch return false) catch return false;
                },
                .window, .agent => if (groups.items.len > 0) {
                    groups.items[groups.items.len - 1].count += 1;
                },
            }
        }
        a.drag_host = .{ .host = h, .serial = h.serial };
        return reorder.begin(a.sidebar, a.sidebar_layer, a.sidebar_scroller, groups.items, dragged, head, a.session_grab_y, .{ .ctx = a, .f = &sessionDropped });
    }

    fn clearDragIds(a: *App) void {
        for (a.drag_ids.items) |id| gpa.free(id);
        a.drag_ids.clearRetainingCapacity();
    }

    /// A dragged session landed: it was the `from`th of the sessions shown for its host and is
    /// to be the `to`th. The server is asked to move it, and the sidebar follows the server.
    fn sessionDropped(ctx: *anyopaque, from: usize, to: usize) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        const h = a.liveHost(a.drag_host orelse return) orelse return;
        const ids = a.drag_ids.items;
        if (from >= ids.len or to >= ids.len or from == to) return;
        const sessions = h.server.sessions.items;
        // Moved up, it goes before the session whose place it takes. Moved down, before
        // whichever session follows the one it lands under, or to the very end.
        var before: ?[]const u8 = null;
        if (to < from) {
            before = ids[to];
        } else for (sessions, 0..) |session, k| if (std.mem.eql(u8, session.id, ids[to])) {
            var next = k + 1;
            if (next < sessions.len and std.mem.eql(u8, sessions[next].id, ids[from])) next += 1;
            if (next < sessions.len) before = sessions[next].id;
            break;
        };
        h.server.moveSession(ids[from], before);
    }

    /// Moves the shown session one place up or down the sidebar.
    fn moveSessionStep(a: *App, session_id: []const u8, down: bool) void {
        const s = a.server orelse return;
        for (s.sessions.items, 0..) |session, i| if (std.mem.eql(u8, session.id, session_id)) {
            if (down) {
                if (i + 1 >= s.sessions.items.len) return;
                s.moveSession(session_id, if (i + 2 < s.sessions.items.len) s.sessions.items[i + 2].id else null);
            } else {
                if (i == 0) return;
                s.moveSession(session_id, s.sessions.items[i - 1].id);
            }
            return;
        };
    }

    fn moveSessionUp(a: *App, session_id: []const u8) void {
        a.moveSessionStep(session_id, false);
    }

    fn moveSessionDown(a: *App, session_id: []const u8) void {
        a.moveSessionStep(session_id, true);
    }

    fn renameSessionFromMenu(a: *App, session_id: []const u8) void {
        a.renameSessionAction(session_id);
    }

    /// The number of panes that need you, as a badge on the Dock or the desktop's launcher.
    pub fn updateBadge(a: *App) void {
        var n: u32 = 0;
        if (settings.current.unread_badge) for (a.hosts.items) |h| {
            var it = h.server.blocks.iterator();
            while (it.next()) |b| if (b.value_ptr.attention and !@import("small_actions.zig").muted(h, b.key_ptr.*)) {
                n += 1;
            };
        };
        if (n == a.badge_count) return;
        a.badge_count = n;
        if (builtin.os.tag == .macos) return @import("../platform/macos.zig").setBadge(n);
        a.sendBadge();
    }

    /// Unity's launcher entry, which KDE, Plank and Dash to Dock show. The session bus is asked
    /// for once, without waiting; the count goes out when it arrives and on every change after.
    fn sendBadge(a: *App) void {
        const bus = a.badge_bus orelse {
            if (!a.badge_bus_asked) {
                a.badge_bus_asked = true;
                gio.busGet(.session, null, &gotBadgeBus, a);
            }
            return;
        };
        const n = a.badge_count;
        const dict = glib.VariantType.new("a{sv}");
        defer dict.free();
        const props = glib.VariantBuilder.new(dict);
        defer props.unref();
        props.add("{sv}", "count", glib.Variant.newInt64(n));
        props.add("{sv}", "count-visible", glib.Variant.newBoolean(@intFromBool(n > 0)));
        // The tuple is floating, and sending it takes it over along with what it holds.
        const params = glib.Variant.newTuple(&[_]*glib.Variant{ glib.Variant.newString("application://dev.renux.desktop"), props.end() }, 2);
        _ = bus.emitSignal(null, "/dev/renux", "com.canonical.Unity.LauncherEntry", "Update", params, null);
    }

    fn gotBadgeBus(_: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const a: *App = @ptrCast(@alignCast(data.?));
        a.badge_bus = gio.busGetFinish(result, null) orelse return;
        a.sendBadge();
    }

    /// Opens a tab in the shown session that runs a command, such as `rex skill setup`.
    pub fn runInNewTab(a: *App, command: []const u8) void {
        const s = a.server orelse return;
        const sid = a.session_id orelse return a.toast("Open a session first");
        const line = std.fmt.allocPrint(gpa, "{s}\r", .{command}) catch return;
        defer gpa.free(line);
        s.newWindowRunning(sid, line);
    }

    /// Changes the focused pane's shell to a folder.
    pub fn changeDirectory(a: *App, path: []const u8) void {
        const t = a.target() orelse return;
        a.usePath(t[0], t[1], t[2], path, false);
    }

    /// Types a path into a pane, quoted for the shell: as a cd and Enter, or as text to use.
    pub fn usePath(a: *App, s: *Server, session_id: []const u8, block_id: []const u8, path: []const u8, insert: bool) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        if (!insert) out.appendSlice(gpa, "cd ") catch return;
        out.append(gpa, '\'') catch return;
        for (path) |c| if (c == '\'') out.appendSlice(gpa, "'\\''") catch return else out.append(gpa, c) catch return;
        out.append(gpa, '\'') catch return;
        if (insert) out.append(gpa, ' ') catch return else out.append(gpa, '\r') catch return;
        s.writeText(session_id, block_id, out.items);
        if (!insert) settings.addRecentPath(path);
        if (a.workspace) |w| w.grabFocus();
    }

    /// The focused pane's folder as a plain path, from the file:// address its shell reports.
    fn focusedFolder(a: *App, buf: []u8) []const u8 {
        const t = a.target() orelse return "";
        const info = t[0].blockInfo(t[2]) orelse return "";
        const uri = info.folder orelse return "";
        return folderPath(buf, uri);
    }

    fn browse(a: *App, mode: @import("../ui/goto.zig").BrowseMode) bool {
        const t = a.target() orelse return false;
        var buf: [1024]u8 = undefined;
        @import("../ui/goto.zig").openBrowser(a, t[0], t[1], t[2], a.focusedFolder(&buf), mode);
        return true;
    }

    /// Shows a pane wherever it is: its host, session and window, with the keyboard in it.
    pub fn jumpTo(a: *App, h: *Host, session_id: []const u8, window_id: []const u8, block_id: []const u8) void {
        a.selectHost(h);
        a.auto_picked = false;
        setSlot(&a.session_id, session_id);
        setSlot(&a.window_id, window_id);
        h.server.focusWindow(session_id, window_id);
        h.server.focusBlock(session_id, block_id);
        h.server.clearAttention(block_id);
        a.showSelected();
        a.rebuildSidebar();
        if (a.workspace) |w| {
            w.focus(block_id);
            w.grabFocus();
        }
    }

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, a: *App) callconv(.c) void {
        if (a.rebuilding) return;
        // Picking a pane in the sidebar leaves the board for it.
        a.showBoard(false);
        const index: usize = @intCast(row.getIndex());
        if (index >= a.rows.items.len) return;
        const r = a.rows.items[index] orelse return;
        a.selectHost(r.host);
        a.auto_picked = false;
        // An agent's row goes to its very pane.
        if (r.block_id.len > 0) return a.jumpTo(r.host, r.session_id, r.window_id, r.block_id);
        if (r.window_id.len == 0) return a.showSession(r.session_id);
        a.openTab(r.host, r.session_id, r.window_id);
        if (a.workspace) |w| w.grabFocus();
    }

    const ActivePrompt = struct {
        host: *Host,
        call_id: []u8,
        picker: *prompt_ui.Picker,

        fn destroy(p: *ActivePrompt) void {
            gpa.free(p.call_id);
            gpa.destroy(p);
        }
    };

    fn showPrompt(ctx: *anyopaque, call_id: []const u8, payload: prompt_json.Value) bool {
        const h: *Host = @ptrCast(@alignCast(ctx));
        const a = h.app;
        if (a.active_prompt != null) return false;
        const kind = prompt_json.str(payload, "kind") orelse return false;
        const multiple = prompt_json.boolean(payload, "multiple") orelse false;
        const allow_other = prompt_json.boolean(payload, "allow_other") orelse false;
        const mode: @FieldType(prompt_ui.Spec, "mode") = if (std.mem.eql(u8, kind, "input"))
            .input
        else if (!std.mem.eql(u8, kind, "pick") or (multiple and allow_other))
            return false
        else if (multiple)
            .multiple
        else if (allow_other)
            .other
        else
            .single;
        const title = prompt_json.str(payload, "title") orelse return false;
        const rows = if (mode == .input) &.{} else prompt_json.array(payload, "items");
        if (rows.len > 2000) return false;
        const items = gpa.alloc(prompt_ui.Item, rows.len) catch return false;
        defer gpa.free(items);
        for (rows, items) |row, *item| {
            const id = if (row == .string) row.string else prompt_json.str(row, "id") orelse return false;
            item.* = .{
                .id = id,
                .title = prompt_json.str(row, "title") orelse id,
                .subtitle = prompt_json.str(row, "subtitle") orelse "",
                .detail = prompt_json.str(row, "detail") orelse "",
                .icon = prompt_json.str(row, "icon"),
                .selected = prompt_json.boolean(row, "selected") orelse false,
            };
        }
        const p = gpa.create(ActivePrompt) catch return false;
        const owned_id = gpa.dupe(u8, call_id) catch {
            gpa.destroy(p);
            return false;
        };
        p.* = .{ .host = h, .call_id = owned_id, .picker = undefined };
        p.picker = prompt_ui.Picker.open(a.window.as(gtk.Widget), .{
            .title = title,
            .placeholder = prompt_json.str(payload, "placeholder") orelse "",
            .value = prompt_json.str(payload, "value") orelse "",
            .confirm = prompt_json.str(payload, "confirm"),
            .mode = mode,
            .items = items,
        }, p, promptAnswered) catch {
            p.destroy();
            return false;
        };
        a.active_prompt = p;
        return true;
    }

    fn promptAnswered(ctx: *anyopaque, result: prompt_ui.Result) void {
        const p: *ActivePrompt = @ptrCast(@alignCast(ctx));
        p.host.app.active_prompt = null;
        p.host.server.answerPrompt(p.call_id, switch (result) {
            .cancelled => .cancelled,
            .text => |text| .{ .text = text },
            .ids => |ids| .{ .ids = ids },
        });
        p.destroy();
    }

    fn dismissPrompt(ctx: *anyopaque, call_id: ?[]const u8) void {
        const h: *Host = @ptrCast(@alignCast(ctx));
        const p = h.app.active_prompt orelse return;
        if (p.host != h) return;
        if (call_id) |id| if (!std.mem.eql(u8, id, p.call_id)) return;
        h.app.active_prompt = null;
        p.picker.dismiss();
        p.destroy();
    }

    // client.* actions. Key bindings live in the person's Lua config on the server; the server
    // runs its own actions and asks the client for these.

    pub fn perform(ctx: *anyopaque, action: []const u8, args: ?@import("../util/json.zig").Value, session_id: ?[]const u8) bool {
        const done = performInner(ctx, action, args, session_id);
        if (!done) std.log.warn("not performed: {s}", .{action});
        return done;
    }

    fn performInner(ctx: *anyopaque, action: []const u8, args: ?@import("../util/json.zig").Value, session_id: ?[]const u8) bool {
        const h: *Host = @ptrCast(@alignCast(ctx));
        const a = h.app;
        // A key bound on one host acts on that host's sessions.
        a.selectHost(h);
        const J = @import("../util/json.zig");
        if (session_id) |sid| if (!eqlOpt(a.session_id, sid)) {
            a.auto_picked = false;
            setSlot(&a.session_id, sid);
            setSlot(&a.window_id, null);
        };
        if (std.mem.eql(u8, action, "session.select")) {
            setSlot(&a.window_id, J.str(args, "window_id"));
            a.showSelected();
            a.rebuildSidebar();
            return true;
        }
        if (std.mem.eql(u8, action, "client.tab.new")) return a.did(newWindow);
        if (std.mem.eql(u8, action, "client.tab.close")) {
            const s = a.server orelse return false;
            const sid = a.session_id orelse return false;
            const w = a.shownWindow() orelse return false;
            s.closeWindow(sid, w.id);
            return true;
        }
        if (std.mem.eql(u8, action, "client.tab.next")) return a.stepWindow(1);
        if (std.mem.eql(u8, action, "client.tab.previous")) return a.stepWindow(-1);
        if (std.mem.eql(u8, action, "client.tab.goto")) {
            const index = J.int(args, "index") orelse return false;
            return a.gotoWindow(index - 1);
        }
        if (std.mem.startsWith(u8, action, "pane.")) return a.paneAction(action[5..], args);
        if (std.mem.eql(u8, action, "client.find.open")) return a.did(openFind);
        if (std.mem.eql(u8, action, "client.mode.enter")) {
            termview.setKeyMode(J.str(args, "name") orelse return false);
            return true;
        }
        if (std.mem.eql(u8, action, "client.mode.exit")) {
            termview.setKeyMode("");
            return true;
        }
        if (std.mem.startsWith(u8, action, "client.palette.")) return a.did(openPalette);
        if (std.mem.eql(u8, action, "client.sidebar.toggle")) return a.did(toggleSidebar);
        if (std.mem.eql(u8, action, "client.sidebar.focus")) return a.did(focusSidebar);
        if (std.mem.eql(u8, action, "client.board.toggle")) return a.did(toggleBoard);
        if (std.mem.eql(u8, action, "client.overview.toggle")) return a.did(toggleOverview);
        if (std.mem.eql(u8, action, "client.tab.rename")) {
            const sid = a.session_id orelse return false;
            const w = a.shownWindow() orelse return false;
            a.renameWindowAction(sid, w.id);
            return true;
        }
        if (std.mem.eql(u8, action, "client.config.reload")) {
            const s = a.server orelse return false;
            s.reloadConfig();
            a.toast("Config reloaded");
            return true;
        }
        if (std.mem.eql(u8, action, "client.sidebar.activity.toggle") or std.mem.eql(u8, action, "pane.view_activity")) {
            a.activity.toggle();
            return true;
        }
        if (std.mem.eql(u8, action, "client.sidebar.activity.by_priority")) {
            a.activity.setGrouping(.priority);
            return true;
        }
        if (std.mem.eql(u8, action, "client.sidebar.activity.by_session")) {
            a.activity.setGrouping(.session);
            return true;
        }
        if (std.mem.eql(u8, action, "session.new")) return a.did(newSession);
        if (std.mem.eql(u8, action, "session.next")) return a.stepSession(1);
        if (std.mem.eql(u8, action, "session.previous")) return a.stepSession(-1);
        if (std.mem.eql(u8, action, "session.rename")) {
            const sid = a.session_id orelse return false;
            a.renameSessionAction(sid);
            return true;
        }
        if (std.mem.eql(u8, action, "session.switch")) return a.did(switchSession);
        return a.moreActions(action, args);
    }

    /// The rest of Rex's client and session actions that make sense in Renux.
    fn moreActions(a: *App, action: []const u8, args: ?@import("../util/json.zig").Value) bool {
        const J = @import("../util/json.zig");
        const is = struct {
            fn f(x: []const u8, y: []const u8) bool {
                return std.mem.eql(u8, x, y);
            }
        }.f;
        if (is(action, "client.font.increase")) return a.fontStep(1);
        if (is(action, "client.font.decrease")) return a.fontStep(-1);
        if (is(action, "client.font.reset")) return a.fontStep(0);
        if (is(action, "client.find.next")) return a.did(findNext);
        if (is(action, "client.find.previous")) return a.did(findPrev);
        if (is(action, "client.mode.exit_all")) {
            termview.setKeyMode("");
            return true;
        }
        if (is(action, "client.prompt.next")) return a.did(promptNext);
        if (is(action, "client.prompt.previous")) return a.did(promptPrev);
        if (is(action, "client.scroll.page_up")) return a.scrollPage(true);
        if (is(action, "client.scroll.page_down")) return a.scrollPage(false);
        if (is(action, "client.tab.close_others")) return a.closeOtherWindows();
        if (is(action, "client.tab.move.forward")) return a.moveWindowStep(true);
        if (is(action, "client.tab.move.backward")) return a.moveWindowStep(false);
        if (is(action, "client.tab.move")) {
            const by = J.int(args, "offset") orelse J.int(args, "delta") orelse 1;
            return a.moveWindowStep(by > 0);
        }
        if (is(action, "client.window.fullscreen.toggle")) {
            if (a.window.as(gtk.Window).isFullscreen() != 0) a.window.as(gtk.Window).unfullscreen() else a.window.as(gtk.Window).fullscreen();
            return true;
        }
        if (is(action, "client.window.close") or is(action, "client.close")) {
            a.window.as(gtk.Window).close();
            return true;
        }
        if (is(action, "client.visibility.toggle")) {
            a.toggleVisible();
            return true;
        }
        if (is(action, "client.window.new")) return a.openAppWindow(null);
        if (is(action, "client.tab.move_to_new_window")) {
            const w = a.shownWindow() orelse return false;
            const sid = a.session_id orelse return false;
            if (!a.openAppWindow(.{ sid, w.id })) return false;
            // This window moves on, so the tab shows in the new one only: to another tab of the
            // session, or another session when it has just this one.
            const v = (a.server orelse return true).sessionView(sid) orelse return true;
            if (v.windows.len > 1) {
                _ = a.stepWindow(1);
            } else if ((a.server orelse return true).sessions.items.len > 1) {
                _ = a.stepSession(1);
            }
            return true;
        }
        if (is(action, "client.settings") or is(action, "client.theme.change") or is(action, "client.shortcuts.edit") or is(action, "client.theme.import")) return a.did(openSettings);
        if (is(action, "client.appearance.switch_mode")) {
            settings.current.color_scheme = if (adw.StyleManager.getDefault().getDark() != 0) .light else .dark;
            settings.save();
            a.theme_for = null;
            a.applyTheme();
            return true;
        }
        if (is(action, "client.sidebar.filter.focus")) {
            a.split.setShowSidebar(1);
            a.filter_button.popup();
            return true;
        }
        if (is(action, "client.host.forward_port")) return a.did(forwardPort);
        if (is(action, "client.host.add")) {
            a.addHostDialog();
            return true;
        }
        if (is(action, "client.tab_style.toggle")) {
            // Between tabs in the sidebar and tabs above the panes, like Rex.
            settings.current.tab_position = if (settings.current.tab_position == .above) .left else .above;
            settings.save();
            a.tabsChanged();
            return true;
        }
        if (is(action, "client.notice.dismiss")) return true;
        if (is(action, "client.diagnostics") or is(action, "client.debug.copy")) {
            @import("manage.zig").openDiagnostics(a);
            return true;
        }
        if (is(action, "client.onboarding")) {
            @import("manage.zig").openWelcome(a);
            return true;
        }
        if (is(action, "client.agents.setup")) {
            @import("manage.zig").setupAgents(a);
            return true;
        }
        if (is(action, "client.pair_device")) return a.pairDevice();
        if (is(action, "client.config.copy_path")) {
            a.runInNewTab("rex config path");
            return true;
        }
        if (is(action, "client.version.copy")) {
            a.window.as(gtk.Widget).getClipboard().setText("Renux for Linux " ++ build_options.version);
            a.toast("Version copied");
            return true;
        }
        if (is(action, "session.new_window")) return a.did(newWindow);
        if (is(action, "session.close_window")) {
            const s = a.server orelse return false;
            const sid = a.session_id orelse return false;
            const w = a.shownWindow() orelse return false;
            s.closeWindow(sid, w.id);
            return true;
        }
        if (is(action, "session.close")) return a.confirmCloseSession();
        if (is(action, "session.zoom_block")) return a.did(zoomPane);
        if (is(action, "session.focus_next_pane")) return a.focusStep(1);
        if (is(action, "session.focus_previous_pane")) return a.focusStep(-1);
        if (is(action, "session.focus_next_window")) return a.stepWindow(1);
        if (is(action, "session.focus_previous_window")) return a.stepWindow(-1);
        if (is(action, "session.focus_direction")) return a.focusDirection(J.str(args, "direction") orelse return false);
        if (is(action, "session.collapse")) return a.foldSessions(.current, true);
        if (is(action, "session.expand")) return a.foldSessions(.current, false);
        if (is(action, "session.collapse_others")) return a.foldSessions(.others, true);
        return @import("small_actions.zig").perform(a, action);
    }

    pub fn toastText(a: *App, text: [:0]const u8) void {
        a.toast(text);
    }

    /// Shows a message at the bottom. Messages don't wait in line: one that says what is
    /// already showing adds to its count and keeps it up a while longer, and a different one
    /// takes its place. So an error that keeps happening is one line, not a queue of them.
    pub fn toast(a: *App, text: [:0]const u8) void {
        if (a.toast_now) |showing| {
            if (std.mem.eql(u8, a.toast_text.items, text)) {
                a.toast_count += 1;
                var buf: [600]u8 = undefined;
                if (std.fmt.bufPrintSentinel(&buf, "{s} ({d} times)", .{ text, a.toast_count }, 0)) |counted| showing.setTitle(counted.ptr) else |_| {}
                // Adding a message that is showing starts its time again. The overlay takes
                // a reference each time it is given one.
                _ = showing.as(gobject.Object).ref();
                a.toasts.addToast(showing);
                return;
            }
            showing.dismiss();
            // Dismissing may tell `toastGone` at once, or only when the message has slid away.
            if (a.toast_now == showing) {
                a.toast_now = null;
                showing.as(gobject.Object).unref();
            }
        }
        const fresh = adw.Toast.new(text.ptr);
        // Ahead of a download's progress, which stays up for as long as the download takes.
        fresh.setPriority(.high);
        a.toast_text.clearRetainingCapacity();
        a.toast_text.appendSlice(gpa, text) catch {};
        a.toast_count = 1;
        a.toast_now = fresh;
        _ = fresh.as(gobject.Object).ref();
        _ = adw.Toast.signals.dismissed.connect(fresh, *App, &toastGone, a, .{});
        a.toasts.addToast(fresh);
    }

    /// A message left, by itself or because it was closed.
    fn toastGone(gone: *adw.Toast, a: *App) callconv(.c) void {
        if (a.toast_now != gone) return;
        a.toast_now = null;
        gone.as(gobject.Object).unref();
    }

    /// The next or previous session on this host, in the sidebar's order.
    fn stepSession(a: *App, delta: i64) bool {
        // Going to another tab or session leaves the board for it.
        a.showBoard(false);
        const s = a.server orelse return false;
        const n: i64 = @intCast(s.sessions.items.len);
        if (n == 0) return false;
        var i: i64 = 0;
        for (s.sessions.items, 0..) |session, k| if (eqlOpt(a.session_id, session.id)) {
            i = @intCast(k);
        };
        a.showSession(s.sessions.items[@intCast(@mod(i + delta, n))].id);
        return true;
    }

    pub fn showSession(a: *App, session_id: []const u8) void {
        a.auto_picked = false;
        setSlot(&a.session_id, session_id);
        setSlot(&a.window_id, null);
        a.showSelected();
        a.rebuildSidebar();
        if (a.workspace) |w| w.grabFocus();
    }

    /// A list of this host's sessions to jump to, filtered by typing.
    fn switchSession(a: *App) void {
        const s = a.server orelse return;
        const dialog = adw.Dialog.new();
        dialog.setTitle("Switch Session");
        dialog.setContentWidth(420);
        dialog.setContentHeight(360);
        const list = gtk.ListBox.new();
        list.as(gtk.Widget).addCssClass("navigation-sidebar");
        list.setActivateOnSingleClick(1);
        for (s.sessions.items) |session| {
            const z = gpa.dupeSentinel(u8, if (session.label.len > 0) session.label else session.id, 0) catch continue;
            defer gpa.free(z);
            const label = gtk.Label.new(z.ptr);
            label.setXalign(0);
            const row = gtk.ListBoxRow.new();
            row.setChild(label.as(gtk.Widget));
            const id = gpa.dupeSentinel(u8, session.id, 0) catch continue;
            gobject.Object.setDataFull(row.as(gobject.Object), "session", id.ptr, &freeData);
            list.append(row.as(gtk.Widget));
            if (eqlOpt(a.session_id, session.id)) list.selectRow(row);
        }
        const Picked = struct {
            fn run(_: *gtk.ListBox, row: *gtk.ListBoxRow, d: *adw.Dialog) callconv(.c) void {
                const app = mode_app orelse return;
                const id = gobject.Object.getData(row.as(gobject.Object), "session") orelse return;
                const sid: [*:0]const u8 = @ptrCast(id);
                app.showSession(std.mem.span(sid));
                _ = d.close();
            }
        };
        _ = gtk.ListBox.signals.row_activated.connect(list, *adw.Dialog, &Picked.run, dialog, .{});
        const scroller = gtk.ScrolledWindow.new();
        // It scrolls, with no bar drawn: nothing in Renux shows one but a terminal's history.
        scroller.setPolicy(.external, .external);
        scroller.setChild(list.as(gtk.Widget));
        scroller.as(gtk.Widget).addCssClass("palette");
        dialog.setChild(scroller.as(gtk.Widget));
        dialog.present(a.window.as(gtk.Widget));
        if (list.getSelectedRow()) |row| _ = row.as(gtk.Widget).grabFocus();
    }

    fn renameSessionAction(a: *App, session_id: []const u8) void {
        const s = a.server orelse return;
        var current: []const u8 = "";
        for (s.sessions.items) |session| if (std.mem.eql(u8, session.id, session_id)) {
            current = session.label;
        };
        const ctx = a.renameCtx(session_id, "", "") orelse return;
        a.askName("Rename session", current, null, "Rename", ctx);
    }

    /// Rex's pane actions, which each app performs itself.
    fn paneAction(a: *App, name: []const u8, args: ?@import("../util/json.zig").Value) bool {
        const J = @import("../util/json.zig");
        const eql = std.mem.eql;
        if (std.mem.startsWith(u8, name, "copy_mode.")) {
            const tv = (a.workspace orelse return false).focusedView() orelse return false;
            return @import("../terminal/copyview.zig").action(tv, name[10..], args);
        }
        if (eql(u8, name, "zoom")) return a.did(zoomPane);
        if (std.mem.startsWith(u8, name, "focus.")) return a.focusDirection(name[6..]);
        if (std.mem.startsWith(u8, name, "split.")) return a.splitToward(name[6..]);
        if (std.mem.startsWith(u8, name, "move.")) return a.moveToward(name[5..]);
        if (eql(u8, name, "close_others")) return a.closeOthers();
        if (eql(u8, name, "minimize_floating")) return a.did(minimizePane);
        if (eql(u8, name, "minimize_all_floating")) return a.minimizeAllFloating();
        if (eql(u8, name, "new_floating")) return a.newFloatingPane();
        if (eql(u8, name, "rename")) return a.renamePaneAction();
        if (eql(u8, name, "move_to_new_tab")) {
            const t = a.target() orelse return false;
            t[0].moveToNewWindow(t[1], t[2]);
            return true;
        }
        if (eql(u8, name, "move_to_tab")) {
            const index = J.int(args, "index") orelse return a.pickTabFor();
            return a.moveFocusedToTab(index - 1);
        }
        if (eql(u8, name, "go_to")) {
            @import("../ui/goto.zig").openAnything(a);
            return true;
        }
        if (eql(u8, name, "go_to_directory")) return a.browse(.cd);
        if (eql(u8, name, "insert_path")) return a.browse(.insert);
        if (eql(u8, name, "copy") or eql(u8, name, "paste")) {
            const tv = (a.workspace orelse return false).focusedView() orelse return false;
            if (eql(u8, name, "copy")) tv.copySelection(false) else tv.pasteClipboard();
            return true;
        }
        if (eql(u8, name, "select_all")) {
            const ws = a.workspace orelse return false;
            const tv = ws.focusedView() orelse return false;
            tv.selectAll();
            return true;
        }
        if (eql(u8, name, "view_activity")) {
            a.activity.toggle();
            return true;
        }
        if (eql(u8, name, "copy_id")) {
            const t = a.target() orelse return false;
            const z = gpa.dupeSentinel(u8, t[2], 0) catch return false;
            defer gpa.free(z);
            a.window.as(gtk.Widget).getClipboard().setText(z.ptr);
            a.toast("Pane ID copied");
            return true;
        }
        if (eql(u8, name, "close")) return a.did(closePane);
        if (eql(u8, name, "float")) return a.did(floatPane);
        if (eql(u8, name, "focus_next")) return a.focusStep(1);
        if (eql(u8, name, "focus_previous")) return a.focusStep(-1);
        if (eql(u8, name, "split")) {
            const dir = J.str(args, "direction") orelse "right";
            return a.splitToward(if (eql(u8, dir, "vertical")) "down" else if (eql(u8, dir, "horizontal")) "right" else dir);
        }
        if (eql(u8, name, "move")) return a.moveToward(J.str(args, "direction") orelse return false);
        if (eql(u8, name, "resize")) {
            const dir = J.str(args, "direction") orelse return false;
            const amount: f64 = @floatFromInt(J.int(args, "amount") orelse 3);
            return a.resizeFocused(dir, amount);
        }
        if (eql(u8, name, "balance")) return a.balance();
        if (eql(u8, name, "focus")) return a.focusDirection(J.str(args, "direction") orelse return false);
        if (eql(u8, name, "send_key")) {
            // A key the config passes through, such as the prefix itself pressed twice.
            const ws = a.workspace orelse return false;
            const s = a.server orelse return false;
            const sid = a.session_id orelse return false;
            const block = ws.focusedBlock() orelse return false;
            const key = @import("../terminal/keys.zig").fromName(J.str(args, "key") orelse return false) orelse return false;
            // Alone, the key has no binding of its own, so the server hands it to the block.
            s.sendKey(sid, block, key);
            return true;
        }
        return false;
    }

    fn focusDirection(a: *App, dir: []const u8) bool {
        const ws = a.workspace orelse return false;
        const next_pane = ws.neighbor(dir) orelse return true;
        ws.focus(next_pane);
        ws.grabFocus();
        return true;
    }

    /// A new shell beside the focused pane: right, left, down or up, or along its longer side.
    fn splitToward(a: *App, dir: []const u8) bool {
        const t = a.target() orelse return false;
        const eql = std.mem.eql;
        var horizontal = eql(u8, dir, "right") or eql(u8, dir, "left");
        if (eql(u8, dir, "auto")) {
            const ws = a.workspace orelse return false;
            const tv = ws.focusedView() orelse return false;
            horizontal = tv.widget().getWidth() >= tv.widget().getHeight() * 2;
        } else if (!horizontal and !eql(u8, dir, "down") and !eql(u8, dir, "up")) return false;
        t[0].newSplit(t[1], t[2], horizontal, eql(u8, dir, "left") or eql(u8, dir, "up"));
        return true;
    }

    /// Moves the focused pane past its neighbor in a direction.
    fn moveToward(a: *App, dir: []const u8) bool {
        const t = a.target() orelse return false;
        const ws = a.workspace orelse return false;
        const other = ws.neighbor(dir) orelse return true;
        const eql = std.mem.eql;
        t[0].moveBlock(t[1], t[2], other, eql(u8, dir, "left") or eql(u8, dir, "right"), eql(u8, dir, "left") or eql(u8, dir, "up"));
        return true;
    }

    fn closeOthers(a: *App) bool {
        const t = a.target() orelse return false;
        const ws = a.workspace orelse return false;
        for (ws.panes.items) |p| if (!std.mem.eql(u8, p.block_id, t[2])) t[0].closeBlock(t[1], p.block_id);
        return true;
    }

    fn minimizeAllFloating(a: *App) bool {
        const s = a.server orelse return false;
        const sid = a.session_id orelse return false;
        const ws = a.workspace orelse return false;
        var done: [32][]const u8 = undefined;
        var n: usize = 0;
        for (ws.panes.items) |p| if (p.floating) {
            const seen = for (done[0..n]) |d| {
                if (std.mem.eql(u8, d, p.layer_id)) break true;
            } else false;
            if (seen or n == done.len) continue;
            done[n] = p.layer_id;
            n += 1;
            s.setLayerMinimized(sid, p.layer_id, true);
        };
        return true;
    }

    fn newFloatingPane(a: *App) bool {
        const s = a.server orelse return false;
        const sid = a.session_id orelse return false;
        const w = a.shownWindow() orelse return false;
        s.newFloating(sid, w.id, .{ .x = 0.2, .y = 0.15, .w = 0.6, .h = 0.65 });
        return true;
    }

    /// The whole font a step bigger or smaller, or back to where it started.
    fn fontStep(a: *App, delta: i32) bool {
        const z = gpa.dupeSentinel(u8, settings.current.font, 0) catch return false;
        defer gpa.free(z);
        const desc = pango.FontDescription.fromString(z.ptr);
        defer desc.free();
        if (start_font_size == 0) start_font_size = desc.getSize();
        const size = if (delta == 0) start_font_size else std.math.clamp(desc.getSize() + delta * pango.SCALE, 6 * pango.SCALE, 40 * pango.SCALE);
        desc.setSize(size);
        const text = desc.toString();
        defer glib.free(text);
        settings.setString(&settings.current.font, std.mem.span(text));
        a.fontChanged();
        return true;
    }

    fn scrollPage(a: *App, up: bool) bool {
        const ws = a.workspace orelse return false;
        const tv = ws.focusedView() orelse return false;
        const rows = @as(f64, @floatFromInt(tv.widget().getHeight())) / @max(1, tv.cell_h);
        tv.scrollBy(if (up) -rows / 3 else rows / 3);
        return true;
    }

    /// Moves the focused pane beside the first tiled pane of another tab in its session.
    fn moveFocusedToTab(a: *App, index: i64) bool {
        const t = a.target() orelse return false;
        const v = t[0].sessionView(t[1]) orelse return false;
        if (index < 0 or index >= v.windows.len) return false;
        return a.moveBlockToTab(t[0], t[1], t[2], &v.windows[@intCast(index)]);
    }

    /// Puts a pane beside the first other tiled pane of a tab.
    fn moveBlockToTab(a: *App, s: *Server, session_id: []const u8, block_id: []const u8, w: *const view.Window) bool {
        const layer = w.tiled() orelse return false;
        for (layer.blocks) |b| if (!std.mem.eql(u8, b.id, block_id)) {
            s.moveBlock(session_id, block_id, b.id, true, false);
            return true;
        };
        a.toast("That tab has no tiled pane to move beside");
        return true;
    }

    /// Asks which tab to move the focused pane to.
    fn pickTabFor(a: *App) bool {
        const t = a.target() orelse return false;
        const h = a.current orelse return false;
        const v = t[0].sessionView(t[1]) orelse return false;
        const dialog = adw.AlertDialog.new("Move pane to tab", null);
        dialog.addResponse("cancel", "Cancel");
        var buf: [256]u8 = undefined;
        var idbuf: [300]u8 = undefined;
        // Each choice is named by its tab, so the answer still means that tab if tabs have come
        // or gone meanwhile, and it moves the pane that was focused when the question was asked.
        for (v.windows) |*w| {
            const title = rowTitle(h, &buf, w, v);
            const id = std.fmt.bufPrintSentinel(&idbuf, "tab:{s}", .{w.id}, 0) catch continue;
            dialog.addResponse(id.ptr, title.ptr);
        }
        const ctx = a.renameCtx(t[1], "", t[2]) orelse return false;
        const Done = struct {
            fn run(_: *adw.AlertDialog, response: [*:0]const u8, c: *RenameCtx) callconv(.c) void {
                defer c.free();
                const answer = std.mem.span(response);
                if (!std.mem.startsWith(u8, answer, "tab:")) return;
                const host = c.app.liveHost(c.host) orelse return;
                const view_now = host.server.sessionView(c.session_id) orelse return;
                const w = view_now.window(answer[4..]) orelse return;
                _ = c.app.moveBlockToTab(host.server, c.session_id, c.block_id, w);
            }
        };
        _ = adw.AlertDialog.signals.response.connect(dialog, *RenameCtx, &Done.run, ctx, .{});
        dialog.as(adw.Dialog).present(a.window.as(gtk.Widget));
        return true;
    }

    /// Opens another Renux window, a process of its own, optionally showing one tab.
    fn openAppWindow(a: *App, show: ?struct { []const u8, []const u8 }) bool {
        // The new window reads the settings file as it starts, so it must hold every change made here.
        settings.flush();
        var exe: [4096]u8 = undefined;
        const n = std.process.executablePath(@import("../main.zig").io, &exe) catch return false;
        if (n >= exe.len) return false;
        exe[n] = 0;
        var env = glib.getEnviron();
        if (show) |sw| {
            const h = a.current orelse return false;
            const open = std.fmt.allocPrintSentinel(gpa, "{s}\t{s}\t{s}", .{ h.server.url, sw[0], sw[1] }, 0) catch return false;
            defer gpa.free(open);
            env = glib.environSetenv(env, "RENUX_OPEN", open.ptr, 1);
        } else env = glib.environUnsetenv(env, "RENUX_OPEN");
        defer glib.strfreev(@ptrCast(env));
        var argv = [_:null]?[*:0]u8{@ptrCast(&exe)};
        var err: ?*glib.Error = null;
        if (glib.spawnAsync(null, &argv, env, .{}, null, null, null, &err) == 0) {
            if (err) |e| {
                std.log.warn("couldn't open a window: {s}", .{e.f_message orelse ""});
                e.free();
            }
            return false;
        }
        return true;
    }

    /// With autobalance on, splits even out when a pane comes or goes in the shown window.
    fn autobalance(a: *App) void {
        const w = a.shownWindow() orelse return;
        var n: usize = 0;
        if (w.tiled()) |l| n = l.blocks.len;
        const same_window = std.mem.eql(u8, a.balance_window[0..a.balance_window_len], w.id[0..@min(w.id.len, a.balance_window.len)]);
        const changed = same_window and n != a.balance_count;
        a.balance_count = n;
        a.balance_window_len = @min(w.id.len, a.balance_window.len);
        @memcpy(a.balance_window[0..a.balance_window_len], w.id[0..a.balance_window_len]);
        if (changed and n > 1 and settings.current.autobalance) _ = a.balance();
    }

    fn closeOtherWindows(a: *App) bool {
        const s = a.server orelse return false;
        const sid = a.session_id orelse return false;
        const v = s.sessionView(sid) orelse return false;
        const w = a.shownWindow() orelse return false;
        for (v.windows) |*other| if (other != w) s.closeWindow(sid, other.id);
        return true;
    }

    /// Moves the shown window one place earlier or later in the session.
    fn moveWindowStep(a: *App, forward: bool) bool {
        const s = a.server orelse return false;
        const sid = a.session_id orelse return false;
        const v = s.sessionView(sid) orelse return false;
        const w = a.shownWindow() orelse return false;
        for (v.windows, 0..) |*other, i| if (other == w) {
            if (forward) {
                if (i + 1 >= v.windows.len) return true;
                s.moveWindow(sid, w.id, if (i + 2 < v.windows.len) v.windows[i + 2].id else null);
            } else {
                if (i == 0) return true;
                s.moveWindow(sid, w.id, v.windows[i - 1].id);
            }
            return true;
        };
        return false;
    }

    fn setCollapsed(a: *App, session_id: []const u8, fold: bool) void {
        if (fold) {
            if (a.collapsed.contains(session_id)) return;
            const key = gpa.dupe(u8, session_id) catch return;
            a.collapsed.put(gpa, key, {}) catch gpa.free(key);
        } else if (a.collapsed.fetchRemove(session_id)) |e| gpa.free(e.key);
    }

    fn foldSessions(a: *App, which: enum { current, others }, fold: bool) bool {
        const s = a.server orelse return false;
        const sid = a.session_id orelse return false;
        for (s.sessions.items) |session| {
            const is_current = std.mem.eql(u8, session.id, sid);
            if ((which == .current) == is_current) a.setCollapsed(session.id, fold);
        }
        a.rebuildSidebar();
        return true;
    }

    fn confirmCloseSession(a: *App) bool {
        const sid = a.session_id orelse return false;
        return a.confirmCloseSessionOn(a.current orelse return false, sid);
    }

    /// The host a session is on, whichever host is shown.
    fn hostOfSession(a: *App, session_id: []const u8) ?*Host {
        for (a.hosts.items) |h| for (h.server.sessions.items) |session| {
            if (std.mem.eql(u8, session.id, session_id)) return h;
        };
        return null;
    }

    /// "Delete Session" in a session's menu. A session with nothing in it just goes; one with
    /// programs running asks first.
    fn deleteSessionFromMenu(a: *App, session_id: []const u8) void {
        const h = a.hostOfSession(session_id) orelse return;
        const empty = if (h.server.sessionView(session_id)) |v| v.windows.len == 0 else false;
        if (empty) return h.server.destroySession(session_id);
        _ = a.confirmCloseSessionOn(h, session_id);
    }

    fn confirmCloseSessionOn(a: *App, host: *Host, sid: []const u8) bool {
        const dialog = adw.AlertDialog.new("Close this session?", "Every window and program in it ends.");
        dialog.as(gtk.Widget).addCssClass("close-session-confirmation");
        dialog.addResponse("close", "Close Session");
        dialog.addResponse("cancel", "Cancel");
        dialog.setResponseAppearance("close", .destructive);
        dialog.setDefaultResponse("cancel");
        dialog.setCloseResponse("cancel");
        // The session and its host as they are now: another may be shown by the time it's answered.
        const ctx = a.renameCtxOn(host, sid, "", "") orelse return false;
        const Done = struct {
            fn run(_: *adw.AlertDialog, response: [*:0]const u8, c: *RenameCtx) callconv(.c) void {
                defer c.free();
                if (!std.mem.eql(u8, std.mem.span(response), "close")) return;
                const h = c.app.liveHost(c.host) orelse return;
                h.server.destroySession(c.session_id);
            }
        };
        _ = adw.AlertDialog.signals.response.connect(dialog, *RenameCtx, &Done.run, ctx, .{});
        dialog.as(adw.Dialog).present(a.window.as(gtk.Widget));
        return true;
    }

    fn focusStep(a: *App, delta: i64) bool {
        const ws = a.workspace orelse return false;
        const n: i64 = @intCast(ws.panes.items.len);
        if (n == 0) return false;
        const cur = ws.focusedBlock() orelse ws.panes.items[0].block_id;
        var i: i64 = 0;
        for (ws.panes.items, 0..) |p, k| if (std.mem.eql(u8, p.block_id, cur)) {
            i = @intCast(k);
        };
        const next = ws.panes.items[@intCast(@mod(i + delta, n))];
        ws.focus(next.block_id);
        _ = next.term.widget().grabFocus();
        return true;
    }

    /// Moves the border of the focused pane's nearest split in that direction, by `amount` cells.
    fn resizeFocused(a: *App, dir: []const u8, amount: f64) bool {
        const s = a.server orelse return false;
        const sid = a.session_id orelse return false;
        const ws = a.workspace orelse return false;
        const block = ws.focusedBlock() orelse return false;
        const v = s.sessionView(sid) orelse return false;
        const w = v.windowOf(block) orelse return false;
        const root = (w.tiled() orelse return false).layout orelse return false;
        const horizontal = std.mem.eql(u8, dir, "left") or std.mem.eql(u8, dir, "right");
        const grow = std.mem.eql(u8, dir, "right") or std.mem.eql(u8, dir, "down");
        const split = nearestSplit(root, block, horizontal) orelse return false;
        const tv = ws.focusedView() orelse return false;
        // One cell, as a share of the split's size on screen.
        const across: f64 = @floatFromInt(if (horizontal) ws.root.getWidth() else ws.root.getHeight());
        const cell = if (horizontal) tv.cell_w else tv.cell_h;
        const size = (if (horizontal) split.rect.w else split.rect.h) * across;
        const delta = amount * cell / @max(1, size);
        const now = glib.getMonotonicTime();
        const recent = now - last_ratio_at < 1_500_000 and std.mem.eql(u8, last_split[0..last_split_len], split.id);
        const from = if (recent) last_ratio else split.ratio;
        const ratio = std.math.clamp(from + (if (grow) delta else -delta), 0.05, 0.95);
        const n = @min(split.id.len, last_split.len);
        @memcpy(last_split[0..n], split.id[0..n]);
        last_split_len = n;
        last_ratio = ratio;
        last_ratio_at = now;
        s.resizePane(sid, horizontal, firstLeafOf(split.before), firstLeafOf(split.after), ratio);
        return true;
    }

    /// Gives every split the share its panes would have if all were the same size.
    fn balance(a: *App) bool {
        const s = a.server orelse return false;
        const sid = a.session_id orelse return false;
        const w = a.shownWindow() orelse return false;
        const root = (w.tiled() orelse return false).layout orelse return false;
        balanceNode(s, sid, root);
        return true;
    }

    fn did(a: *App, comptime f: fn (*App) void) bool {
        f(a);
        return true;
    }

    fn shownWindow(a: *App) ?*const view.Window {
        const s = a.server orelse return null;
        const v = s.sessionView(a.session_id orelse return null) orelse return null;
        return (if (a.window_id) |wid| v.window(wid) else null) orelse v.activeWindow();
    }

    fn stepWindow(a: *App, delta: i64) bool {
        // Going to another tab or session leaves the board for it.
        a.showBoard(false);
        const s = a.server orelse return false;
        const v = s.sessionView(a.session_id orelse return false) orelse return false;
        const w = a.shownWindow() orelse return false;
        const n: i64 = @intCast(v.windows.len);
        for (v.windows, 0..) |*other, i| if (other == w) return a.gotoWindow(@mod(@as(i64, @intCast(i)) + delta, n));
        return false;
    }

    fn gotoWindow(a: *App, index: i64) bool {
        const s = a.server orelse return false;
        const sid = a.session_id orelse return false;
        const v = s.sessionView(sid) orelse return false;
        if (index < 0 or index >= v.windows.len) return false;
        const w = v.windows[@intCast(index)];
        setSlot(&a.window_id, w.id);
        s.focusWindow(sid, w.id);
        a.showSelected();
        if (a.workspace) |ws| ws.grabFocus();
        return true;
    }

    // Actions, for the menu.

    fn addActions(a: *App) void {
        const entries = [_]struct { [:0]const u8, *const fn (*App) void, [:0]const u8 }{
            .{ "split-right", splitRight, "" },
            .{ "split-down", splitDown, "" },
            .{ "close-pane", closePane, "" },
            .{ "zoom-pane", zoomPane, "" },
            .{ "new-window", newWindow, "" },
            .{ "new-session", newSession, "" },
            .{ "retry", retry, "" },
            .{ "change-server", changeServer, "" },
            .{ "toggle-sidebar", toggleSidebar, "" },
            .{ "overview", toggleOverview, "" },
            .{ "palette", openPalette, "" },
            .{ "settings", openSettings, "" },
            .{ "add-host", addHostDialog, "" },
            .{ "forward-port", forwardPort, "" },
            .{ "pane-float-focused", floatPane, "" },
            .{ "find", openFind, "" },
            .{ "board", toggleBoard, "" },
            .{ "agents", toggleAgents, "" },
            .{ "prompt-prev", promptPrev, "" },
            .{ "prompt-next", promptNext, "" },
            .{ "find-next", findNext, "" },
            .{ "find-prev", findPrev, "" },
            .{ "find-close", closeFind, "" },
        };
        // A pane's own buttons name the pane, which is focused first so the action acts on it.
        inline for (.{
            .{ "pane-split-right", splitRight },
            .{ "pane-split-down", splitDown },
            .{ "pane-zoom", zoomPane },
            .{ "pane-close", closePane },
            .{ "pane-float", floatPane },
            .{ "pane-minimize", minimizePane },
        }) |e| {
            const action = gio.SimpleAction.new(e[0], glib.VariantType.new("s"));
            const Thunk = struct {
                fn run(_: *gio.SimpleAction, param: ?*glib.Variant, app: *App) callconv(.c) void {
                    const block = std.mem.span(param.?.getString(null));
                    if (app.workspace) |ws| ws.focus(block);
                    e[1](app);
                }
            };
            _ = gio.SimpleAction.signals.activate.connect(action, *App, &Thunk.run, a, .{});
            a.app.as(gio.ActionMap).addAction(action.as(gio.Action));
        }
        {
            const action = gio.SimpleAction.new("restore-layer", glib.VariantType.new("s"));
            const Thunk = struct {
                fn run(_: *gio.SimpleAction, param: ?*glib.Variant, app: *App) callconv(.c) void {
                    const layer = std.mem.span(param.?.getString(null));
                    const s = app.server orelse return;
                    const sid = app.session_id orelse return;
                    s.setLayerMinimized(sid, layer, false);
                }
            };
            _ = gio.SimpleAction.signals.activate.connect(action, *App, &Thunk.run, a, .{});
            a.app.as(gio.ActionMap).addAction(action.as(gio.Action));
        }
        {
            const action = gio.SimpleAction.newStateful("tight", null, glib.Variant.newBoolean(@intFromBool(settings.current.tight)));
            const Thunk = struct {
                fn run(act: *gio.SimpleAction, _: ?*glib.Variant, app: *App) callconv(.c) void {
                    const on = !Workspace.isTight();
                    act.setState(glib.Variant.newBoolean(@intFromBool(on)));
                    app.setTight(on);
                }
            };
            _ = gio.SimpleAction.signals.activate.connect(action, *App, &Thunk.run, a, .{});
            a.app.as(gio.ActionMap).addAction(action.as(gio.Action));
        }
        inline for (.{ .{ "new-window-in", newWindowIn }, .{ "toggle-session", toggleSession }, .{ "filter", filterAction }, .{ "move-session-up", moveSessionUp }, .{ "move-session-down", moveSessionDown }, .{ "rename-session", renameSessionFromMenu }, .{ "delete-session", deleteSessionFromMenu } }) |e| {
            const action = gio.SimpleAction.new(e[0], glib.VariantType.new("s"));
            const Thunk = struct {
                fn run(_: *gio.SimpleAction, param: ?*glib.Variant, app: *App) callconv(.c) void {
                    e[1](app, std.mem.span(param.?.getString(null)));
                }
            };
            _ = gio.SimpleAction.signals.activate.connect(action, *App, &Thunk.run, a, .{});
            a.app.as(gio.ActionMap).addAction(action.as(gio.Action));
        }
        inline for (.{ .{ "close-window", closeWindowAction }, .{ "rename-window", renameWindowAction }, .{ "show-block", showBlockAction }, .{ "show-window", showWindowAction } }) |e| {
            const action = gio.SimpleAction.new(e[0], glib.VariantType.new("s"));
            const Thunk = struct {
                fn run(_: *gio.SimpleAction, param: ?*glib.Variant, app: *App) callconv(.c) void {
                    const text = std.mem.span(param.?.getString(null));
                    const space = std.mem.lastIndexOfScalar(u8, text, ' ') orelse return;
                    e[1](app, text[0..space], text[space + 1 ..]);
                }
            };
            _ = gio.SimpleAction.signals.activate.connect(action, *App, &Thunk.run, a, .{});
            a.app.as(gio.ActionMap).addAction(action.as(gio.Action));
        }
        inline for (entries) |e| {
            const action = gio.SimpleAction.new(e[0], null);
            const Thunk = struct {
                fn run(_: *gio.SimpleAction, _: ?*glib.Variant, app: *App) callconv(.c) void {
                    e[1](app);
                }
            };
            _ = gio.SimpleAction.signals.activate.connect(action, *App, &Thunk.run, a, .{});
            a.app.as(gio.ActionMap).addAction(action.as(gio.Action));
            if (e[2].len > 0) {
                const accels = [_:null]?[*:0]const u8{e[2].ptr};
                var name_buf: [64]u8 = undefined;
                const name = std.fmt.bufPrintSentinel(&name_buf, "app.{s}", .{e[0]}, 0) catch unreachable;
                a.app.as(gtk.Application).setAccelsForAction(name.ptr, &accels);
            }
        }
    }

    fn target(a: *App) ?struct { *Server, []const u8, []const u8 } {
        const s = a.server orelse return null;
        const ws = a.workspace orelse return null;
        const sid = a.session_id orelse return null;
        const block = ws.focusedBlock() orelse return null;
        return .{ s, sid, block };
    }

    fn splitRight(a: *App) void {
        const t = a.target() orelse return;
        t[0].newSplit(t[1], t[2], true, false);
    }

    fn splitDown(a: *App) void {
        const t = a.target() orelse return;
        t[0].newSplit(t[1], t[2], false, false);
    }

    fn closePane(a: *App) void {
        const t = a.target() orelse return;
        t[0].closeBlock(t[1], t[2]);
    }

    fn zoomPane(a: *App) void {
        const t = a.target() orelse return;
        const v = t[0].sessionView(t[1]) orelse return;
        const w = v.windowOf(t[2]) orelse return;
        t[0].zoomBlock(t[1], t[2], w.zoomed_block_id == null);
    }

    /// Where a pane goes when it floats: the middle of the window.
    const float_bounds: view.Rect = .{ .x = 0.2, .y = 0.15, .w = 0.6, .h = 0.65 };

    /// Floats a tiled pane in the middle of the window, or puts a floating one back in the tiles.
    fn floatPane(a: *App) void {
        const t = a.target() orelse return;
        const ws = a.workspace orelse return;
        const p = ws.paneOf(t[2]) orelse return;
        if (!p.floating) {
            // The window's last tiled pane stays where it is; see `Workspace.canFloat`.
            if (ws.canFloat(p)) t[0].floatBlock(t[1], t[2], float_bounds);
            return;
        }
        // Back beside a tiled pane, at the right of the layout.
        for (ws.panes.items) |other| if (!other.floating) {
            return t[0].moveBlock(t[1], t[2], other.block_id, true, false);
        };
        // Rex can only dock beside a tiled pane. With none left (the tiled ones closed), the
        // layer fills the window instead, and the same button floats it again.
        const filling = p.bounds.x < 0.01 and p.bounds.y < 0.01 and p.bounds.w > 0.99 and p.bounds.h > 0.99;
        t[0].resizeLayer(t[1], p.layer_id, if (filling) float_bounds else .{ .x = 0, .y = 0, .w = 1, .h = 1 });
    }

    /// Minimizes a pane to the tray. A tiled pane floats first, then goes once the server says so.
    fn minimizePane(a: *App) void {
        const t = a.target() orelse return;
        const ws = a.workspace orelse return;
        const p = ws.paneOf(t[2]) orelse return;
        // Rex keeps a window's last visible panes on screen.
        if (!ws.canMinimize(p)) return;
        ws.startMinimize(t[2]);
        if (p.floating) return t[0].setLayerMinimized(t[1], p.layer_id, true);
        setSlot(&a.minimize_next, t[2]);
        t[0].floatBlock(t[1], t[2], float_bounds);
    }

    /// Finishes a minimize that had to float the pane first.
    fn finishMinimize(a: *App) void {
        const block = a.minimize_next orelse return;
        const ws = a.workspace orelse return;
        const p = ws.paneOf(block) orelse return;
        if (!p.floating) return;
        if (a.server) |s| if (a.session_id) |sid| s.setLayerMinimized(sid, p.layer_id, true);
        setSlot(&a.minimize_next, null);
    }

    pub fn setTight(a: *App, on: bool) void {
        @import("../ui/workspace.zig").setTight(on);
        if (settings.current.tight != on) {
            settings.current.tight = on;
            settings.save();
        }
        if (on) a.window.as(gtk.Widget).addCssClass("tight") else a.window.as(gtk.Widget).removeCssClass("tight");
        if (a.workspace) |ws| ws.root.queueAllocate();
    }

    fn newWindow(a: *App) void {
        const s = a.server orelse return;
        const sid = a.session_id orelse return;
        setSlot(&a.window_id, null); // follow the new active window
        s.newWindow(sid);
    }

    /// Asks for the new session's name first; left empty, the server picks one.
    fn newSession(a: *App) void {
        if (a.server == null) return;
        const ctx = a.renameCtx("", "", "") orelse return;
        ctx.create = true;
        a.askName("New session", "", "Name, or leave empty for a random one", "Create", ctx);
    }

    fn renamePaneAction(a: *App) bool {
        const t = a.target() orelse return false;
        const info = t[0].blockInfo(t[2]);
        const current: []const u8 = if (info) |i| (i.title orelse "") else "";
        const ctx = a.renameCtx(t[1], "", t[2]) orelse return false;
        a.askName("Rename pane", current, null, "Rename", ctx);
        return true;
    }

    fn retry(a: *App) void {
        if (a.server) |s| s.retry();
    }

    fn closeWindowAction(a: *App, session_id: []const u8, window_id: []const u8) void {
        if (a.server) |s| s.closeWindow(session_id, window_id);
    }

    fn renameWindowAction(a: *App, session_id: []const u8, window_id: []const u8) void {
        const s = a.server orelse return;
        const v = s.sessionView(session_id) orelse return;
        const w = v.window(window_id) orelse return;
        var buf: [256]u8 = undefined;
        const current = windowTitle(&buf, w, v);
        const ctx = a.renameCtx(session_id, window_id, "") orelse return;
        a.askName("Rename window", current, null, "Rename", ctx);
    }

    const RenameCtx = struct {
        app: *App,
        /// The host shown when the dialog opened, which is the one the name is for.
        host: HostRef,
        entry: *gtk.Entry,
        session_id: []u8,
        window_id: []u8,
        /// Set when a pane is renamed.
        block_id: []u8,
        /// Set when the name is for a session about to be created.
        create: bool = false,
        /// For a new session with more than one host to put it on: the list to pick from, and
        /// the hosts it names, in its order.
        picker: ?*gtk.DropDown = null,
        choices: []HostRef = &.{},

        fn free(ctx: *RenameCtx) void {
            gpa.free(ctx.choices);
            gpa.free(ctx.session_id);
            gpa.free(ctx.window_id);
            gpa.free(ctx.block_id);
            gpa.destroy(ctx);
        }
    };

    /// What a name dialog needs to act on the shown host later: the session, and the window or
    /// pane when the name is for one of those. `askName` takes it over.
    fn renameCtx(a: *App, session_id: []const u8, window_id: []const u8, block_id: []const u8) ?*RenameCtx {
        return a.renameCtxOn(a.current orelse return null, session_id, window_id, block_id);
    }

    fn renameCtxOn(a: *App, h: *Host, session_id: []const u8, window_id: []const u8, block_id: []const u8) ?*RenameCtx {
        const ctx = gpa.create(RenameCtx) catch return null;
        ctx.* = .{ .app = a, .host = refHost(h), .entry = undefined, .session_id = &.{}, .window_id = &.{}, .block_id = &.{} };
        ctx.session_id = gpa.dupe(u8, session_id) catch return failed(ctx);
        ctx.window_id = gpa.dupe(u8, window_id) catch return failed(ctx);
        ctx.block_id = gpa.dupe(u8, block_id) catch return failed(ctx);
        return ctx;
    }

    fn failed(ctx: *RenameCtx) ?*RenameCtx {
        ctx.free();
        return null;
    }

    fn renamed(_: *adw.AlertDialog, response: [*:0]const u8, ctx: *RenameCtx) callconv(.c) void {
        defer ctx.free();
        if (!std.mem.eql(u8, std.mem.span(response), "rename")) return;
        const label = std.mem.trim(u8, std.mem.span(ctx.entry.as(gtk.Editable).getText()), " ");
        if (ctx.create) {
            // The host picked in the dialog, which starts on the one shown when it opened.
            const picked = if (ctx.picker) |list| list.getSelected() else 0;
            const h = ctx.app.liveHost(if (picked < ctx.choices.len) ctx.choices[picked] else ctx.host) orelse return;
            ctx.app.selectHost(h);
            return h.server.createSession(label);
        }
        // The host the dialog was opened for, even if another is shown by now.
        const s = (ctx.app.liveHost(ctx.host) orelse return).server;
        if (ctx.block_id.len > 0) return s.renameBlock(ctx.session_id, ctx.block_id, label);
        // No window means the session itself is renamed.
        if (ctx.window_id.len == 0) s.renameSession(ctx.session_id, label) else s.renameWindow(ctx.session_id, ctx.window_id, label);
    }

    /// Asks for a name in a small dialog, then acts on it as `ctx` says.
    fn askName(a: *App, title: [:0]const u8, current: []const u8, placeholder: ?[:0]const u8, ok: [:0]const u8, ctx: *RenameCtx) void {
        const z = gpa.dupeSentinel(u8, current, 0) catch return ctx.free();
        defer gpa.free(z);
        const dialog = adw.AlertDialog.new(title.ptr, null);
        const entry = gtk.Entry.new();
        entry.as(gtk.Editable).setText(z.ptr);
        if (placeholder) |p| entry.setPlaceholderText(p.ptr);
        entry.setActivatesDefault(1);
        dialog.setExtraChild(if (ctx.create) a.withHostPicker(ctx, entry) else entry.as(gtk.Widget));
        dialog.addResponse("cancel", "Cancel");
        dialog.addResponse("rename", ok.ptr);
        dialog.setResponseAppearance("rename", .suggested);
        dialog.setDefaultResponse("rename");
        ctx.entry = entry;
        _ = adw.AlertDialog.signals.response.connect(dialog, *RenameCtx, &renamed, ctx, .{});
        dialog.as(adw.Dialog).present(a.window.as(gtk.Widget));
        _ = entry.as(gtk.Widget).grabFocus();
    }

    /// A new session's name field with, under it, the host to make the session on, when
    /// there is more than one connected. It starts on the host being shown, which is where
    /// the person was typing.
    fn withHostPicker(a: *App, ctx: *RenameCtx, entry: *gtk.Entry) *gtk.Widget {
        var names: std.ArrayList(?[*:0]const u8) = .empty;
        var refs: std.ArrayList(HostRef) = .empty;
        defer {
            for (names.items) |n| if (n) |z| gpa.free(std.mem.span(z));
            names.deinit(gpa);
            refs.deinit(gpa);
        }
        var shown: u32 = 0;
        for (a.hosts.items) |h| {
            if (h != a.current and h.server.state != .online) continue;
            const z = gpa.dupeSentinel(u8, h.label, 0) catch continue;
            names.append(gpa, z.ptr) catch {
                gpa.free(z);
                continue;
            };
            refs.append(gpa, refHost(h)) catch {
                gpa.free(z);
                _ = names.pop();
                continue;
            };
            if (h == a.current) shown = @intCast(refs.items.len - 1);
        }
        if (refs.items.len < 2) return entry.as(gtk.Widget);
        names.append(gpa, null) catch return entry.as(gtk.Widget);
        ctx.choices = gpa.dupe(HostRef, refs.items) catch return entry.as(gtk.Widget);
        const list = gtk.DropDown.newFromStrings(@ptrCast(names.items.ptr));
        list.setSelected(shown);
        list.as(gtk.Widget).setHexpand(1);
        ctx.picker = list;
        const row = gtk.Box.new(.horizontal, 10);
        const caption = gtk.Label.new("On");
        caption.as(gtk.Widget).addCssClass("dim-label");
        row.append(caption.as(gtk.Widget));
        row.append(list.as(gtk.Widget));
        const box = gtk.Box.new(.vertical, 10);
        box.append(entry.as(gtk.Widget));
        box.append(row.as(gtk.Widget));
        return box.as(gtk.Widget);
    }

    // Find: each pane has its own bar; these act on the highlighted pane's.

    fn focusedFind(a: *App) ?*@import("../ui/findbar.zig").FindBar {
        const ws = a.workspace orelse return null;
        return ws.focusedFind();
    }

    fn openFind(a: *App) void {
        if (a.focusedFind()) |f| f.open();
    }

    fn closeFind(a: *App) void {
        if (a.focusedFind()) |f| f.close();
    }

    fn findNext(a: *App) void {
        if (a.focusedFind()) |f| f.step(true);
    }

    fn findPrev(a: *App) void {
        if (a.focusedFind()) |f| f.step(false);
    }

    fn openPalette(a: *App) void {
        const s = a.server orelse return;
        const sid = a.session_id orelse return;
        const block = if (a.workspace) |ws| ws.focusedBlock() else null;
        Palette.open(s, a.app.as(gtk.Application), a.window.as(gtk.Widget), sid, block);
    }

    fn forwardPort(a: *App) void {
        const s = a.server orelse return;
        const sid = a.session_id orelse return;
        const block = if (a.workspace) |ws| ws.focusedBlock() else null;
        @import("../ui/ports.zig").show(a.window.as(gtk.Widget), s, sid, block);
    }

    // Settings.

    fn openSettings(a: *App) void {
        @import("../settings/settings_window.zig").open(a);
    }

    /// Applies the terminal font from the settings to every pane.
    pub fn fontChanged(a: *App) void {
        const name = gpa.dupeSentinel(u8, settings.current.font, 0) catch return;
        defer gpa.free(name);
        // The new font is in place before the old one is freed, and every pane then drops what
        // it drew with the old one.
        var old = termview.font;
        termview.font = termview.Font.init(name);
        if (old) |*f| f.deinit();
        for (a.hosts.items) |h| h.workspace.fontChanged();
    }

    /// Applies the theme setting: every terminal recolors, and so does the window.
    /// Whether the computer is set to a dark appearance: the desktop's preference on Linux,
    /// the system setting on the Mac.
    fn systemDark() bool {
        if (builtin.os.tag == .macos) return @import("../platform/macos.zig").systemDark();
        // GTK's own setting can't say: Renux forces a scheme to match its theme, which that
        // setting then repeats, and GTK before 4.20 doesn't have it. The desktop's settings
        // portal can, and `watchAppearance` keeps this up to date from it.
        return linux_dark;
    }

    /// The desktop prefers a dark appearance, as last heard. No preference counts as light.
    var linux_dark: bool = false;

    const portal_name = "org.freedesktop.portal.Desktop";
    const portal_path = "/org/freedesktop/portal/desktop";
    const portal_settings = "org.freedesktop.portal.Settings";
    const appearance_namespace = "org.freedesktop.appearance";

    /// Follows the desktop's light or dark preference through its settings portal: the value now,
    /// and every change after. A desktop without the portal keeps what libadwaita said at launch.
    fn watchAppearance(a: *App) void {
        gio.busGet(.session, null, &gotAppearanceBus, a);
    }

    fn gotAppearanceBus(_: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const a: *App = @ptrCast(@alignCast(data.?));
        // The session bus everything shares; this reference lasts as long as Renux runs.
        const bus = gio.busGetFinish(result, null) orelse return;
        _ = bus.signalSubscribe(portal_name, portal_settings, "SettingChanged", portal_path, appearance_namespace, .{}, &appearanceSignal, a, null);
        const args = glib.Variant.newTuple(&[_]*glib.Variant{ glib.Variant.newString(appearance_namespace), glib.Variant.newString("color-scheme") }, 2);
        bus.call(portal_name, portal_path, portal_settings, "Read", args, null, .{}, 2000, null, &appearanceRead, a);
    }

    fn appearanceRead(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const a: *App = @ptrCast(@alignCast(data.?));
        const bus: *gio.DBusConnection = @ptrCast(@alignCast(source orelse return));
        const reply = bus.callFinish(result, null) orelse return;
        defer reply.unref();
        if (!std.mem.eql(u8, std.mem.span(reply.getTypeString()), "(v)")) return;
        const value = reply.getChildValue(0);
        defer value.unref();
        a.appearanceIs(value);
    }

    fn appearanceSignal(_: *gio.DBusConnection, _: ?[*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, params: *glib.Variant, data: ?*anyopaque) callconv(.c) void {
        const a: *App = @ptrCast(@alignCast(data.?));
        if (!std.mem.eql(u8, std.mem.span(params.getTypeString()), "(ssv)")) return;
        const key = params.getChildValue(1);
        defer key.unref();
        if (!std.mem.eql(u8, std.mem.span(key.getString(null)), "color-scheme")) return;
        const value = params.getChildValue(2);
        defer value.unref();
        a.appearanceIs(value);
    }

    /// Takes the portal's color-scheme value, however many variants wrap it: 1 prefers dark,
    /// while 0 (no preference) and 2 (prefers light) don't.
    fn appearanceIs(a: *App, wrapped: *glib.Variant) void {
        var v = wrapped.ref();
        defer v.unref();
        while (std.mem.eql(u8, std.mem.span(v.getTypeString()), "v")) {
            const inner = v.getVariant();
            v.unref();
            v = inner;
        }
        if (!std.mem.eql(u8, std.mem.span(v.getTypeString()), "u")) return;
        const dark = v.getUint32() == 1;
        if (dark == linux_dark) return;
        linux_dark = dark;
        if (settings.current.theme_follow_system and dark != a.last_dark) a.themeChanged();
    }

    /// The theme in effect: the one picked, or with separate light and dark themes the one for
    /// the system's appearance now.
    fn effectiveTheme() []const u8 {
        const st = &settings.current;
        if (!st.theme_follow_system) return st.theme;
        return if (systemDark()) st.theme_dark else st.theme_light;
    }

    /// Checks the Mac's appearance every few seconds while themes follow it.
    fn appearanceTick(data: ?*anyopaque) callconv(.c) c_int {
        const a: *App = @ptrCast(@alignCast(data.?));
        if (!settings.current.theme_follow_system) return 1;
        const dark = systemDark();
        if (dark != a.last_dark) {
            a.last_dark = dark;
            a.themeChanged();
        }
        return 1;
    }

    pub fn themeChanged(a: *App) void {
        a.last_dark = systemDark();
        themes.active = themes.resolve(effectiveTheme());
        for (a.hosts.items) |h| {
            var it = h.server.streams.valueIterator();
            while (it.next()) |st| st.*.hostColorsChanged();
        }
        a.theme_for = null;
        a.applyTheme();
    }

    fn activeChanged(_: *gtk.Window, _: *gobject.ParamSpec, a: *App) callconv(.c) void {
        if (settings.current.fade_inactive_window) a.redrawAll();
        // Coming back to the window is looking again at the pane with the keyboard.
        if (a.current) |h| if (h.workspace.focusedBlock()) |block| if (a.lookingAt(h, block)) h.server.clearAttention(block);
    }

    /// Whether the person is looking at a pane now: it has the keyboard on the host shown, the
    /// window is the one in use, and the board isn't over it.
    fn lookingAt(a: *App, h: *Host, block_id: []const u8) bool {
        if (a.current != h or a.board.shown()) return false;
        if (a.window.as(gtk.Window).isActive() == 0) return false;
        const focused = h.workspace.focusedBlock() orelse return false;
        return std.mem.eql(u8, focused, block_id);
    }

    /// Applies the window and terminal opacity and the blur behind them.
    pub fn applyLook(a: *App) void {
        const prefs = &settings.current;
        a.setBare(!prefs.window_background);
        termview.term_opacity = prefs.terminal_opacity;
        const provider = a.look_css orelse blk: {
            const p = gtk.CssProvider.new();
            gtk.StyleContext.addProviderForDisplay(gdk.Display.getDefault().?, p.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
            a.look_css = p;
            break :blk p;
        };
        var buf: [2048]u8 = undefined;
        const see_through = prefs.window_opacity < 1 or prefs.terminal_opacity < 1;
        // A Mac window has round corners. On Linux the desktop decides, as Hyprland does with
        // its own rounding, so the window itself stays square.
        const radius: f64 = if (builtin.os.tag == .macos) window_radius else 0;
        // While see-through, one even background lies under the whole window (`window_bg.zig`):
        // the window, sidebar and board draw none of their own, so they all show that one layer,
        // and each pane lays its own over it, so the panes are frosted more than the window.
        a.window_bg.setVisible(@intFromBool(see_through and !a.bare));
        // Floating cards are cut out of the tiled ones under them, so a tiled pane's text doesn't
        // show through a floating one.
        @import("../ui/workspace.zig").cut_floating = see_through;
        @import("../ui/window_bg.zig").floating_radius = if (prefs.tight) 8 else 11;
        const look_text = if (!see_through) "" else std.fmt.bufPrintSentinel(&buf,
            \\window.renux, window.renux .sidebar-pane, .board {{ background-color: transparent; }}
            \\.window-background {{ border-radius: {d}px; background-color: alpha(@renux_shell, {d:.2}); }}
            \\window.tight .workspace {{ background-color: transparent; }}
            \\.pane-card, .layer-card {{ background-color: transparent; }}
            \\.pane-card .pane-title {{ background-color: alpha(@view_bg_color, {d:.2}); }}
            \\.board-column {{ background-color: alpha(@view_bg_color, {d:.2}); }}
            \\.board-card {{ background-color: alpha(@window_fg_color, 0.05); }}
            \\.board-card:hover {{ background-color: alpha(@window_fg_color, 0.09); }}
        , .{ radius, prefs.window_opacity, prefs.terminal_opacity, prefs.terminal_opacity }, 0) catch "";
        // No line between the sidebar and what is beside it, the panes or the board: neither the
        // split view's divider nor the edge libadwaita gives a sidebar. On Linux, no round
        // corners either.
        const no_divider =
            \\window.renux overlay-split-view > border { background: none; }
            \\window.renux .sidebar-pane, window.renux .sidebar-pane banner > revealer > widget { box-shadow: none; }
            \\
        ;
        const corners: []const u8 = if (builtin.os.tag != .macos)
            "window.renux { border-radius: 0; }"
        else if (see_through)
            std.fmt.comptimePrint("window.renux {{ border-radius: {d}px; }}", .{window_radius})
        else
            "";
        // The active pane's border: its color, how strong, whether it fades in, or none at all.
        var color_buf: [32]u8 = undefined;
        const color: []const u8 = if (prefs.highlight_color != 0) (std.fmt.bufPrint(&color_buf, "#{x:0>6}", .{prefs.highlight_color}) catch "@accent_bg_color") else "@accent_bg_color";
        var hbuf: [1024]u8 = undefined;
        const highlight = if (prefs.highlight_border) std.fmt.bufPrint(&hbuf,
            \\.pane-card.focused, .layer-card.focused {{ border-color: alpha({s}, {d:.2}); }}
            \\.pane-card.focused {{ box-shadow: 0 0 0 1px alpha({s}, {d:.2}), 0 0 8px alpha(black, 0.16); }}
            \\.pane-card.floating.focused {{ box-shadow: 0 0 0 1px alpha({s}, {d:.2}), 0 8px 28px alpha(black, 0.45); }}
            \\{s}
        , .{ color, prefs.highlight_opacity, color, prefs.highlight_opacity * 0.4, color, prefs.highlight_opacity * 0.4, if (prefs.highlight_animate) ".pane-card, .layer-card { transition: border-color 220ms ease-out, box-shadow 220ms ease-out; }" else "" }) catch "" else
            \\.pane-card.focused, .layer-card.focused { border-color: @renux_stroke_subtle; }
            \\.pane-card.focused { box-shadow: 0 0 8px alpha(black, 0.16); }
            \\.pane-card.floating.focused { box-shadow: 0 8px 28px alpha(black, 0.45); }
        ;
        // Without its background the window draws nothing behind the panes. The board, which lies
        // over them, has no window background to show then, so it gets the window's color itself.
        // So does the sidebar, which shows there for as long as the keyboard is in it, as a
        // card of its own beside the panes.
        var bbuf: [512]u8 = undefined;
        const bare_text = if (!a.bare) "" else std.fmt.bufPrint(&bbuf,
            \\window.renux, window.renux .sidebar-pane {{ background-color: transparent; }}
            \\window.renux .board, window.renux .renux-sidebar {{ background-color: alpha(@renux_shell, {d:.2}); }}
        , .{prefs.window_opacity}) catch "";
        var sbuf: [128]u8 = undefined;
        const sidebar_text = std.fmt.bufPrint(&sbuf, ".renux-sidebar list {{ font-size: {d:.2}em; }}", .{prefs.sidebar_text_scale}) catch "";
        // After the highlight's own rules, which these must win over: a card on its way to
        // the tray has no outline or highlight, only the shadow a floating card casts.
        // Compact panes sit edge to edge with no outline, and say which has the keyboard by
        // their title's color. The highlight's own rules above would give the active one its
        // glow back, which showed as a line along whichever of its edges had room for it.
        const to_tray =
            \\window.tight .pane-card.focused:not(.floating) { box-shadow: none; }
            \\.pane-card.to-tray, .pane-card.to-tray.focused { border-color: transparent; box-shadow: none; transition: none; border-radius: 10px; }
            \\.pane-card.floating.to-tray, .pane-card.floating.to-tray.focused { box-shadow: 0 2px 10px alpha(black, 0.3); transition: box-shadow 240ms ease-out; }
            \\.layer-card.to-tray, .layer-card.to-tray.focused { border-color: transparent; transition: none; }
        ;
        const css_text = std.fmt.allocPrintSentinel(gpa, "{s}{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{ no_divider, corners, look_text, bare_text, highlight, sidebar_text, to_tray }, 0) catch return;
        defer gpa.free(css_text);
        provider.loadFromString(css_text.ptr);
        if (builtin.os.tag == .macos) if (a.window.as(gtk.Native).getSurface()) |surface| {
            @import("../platform/macos.zig").setBlur(surface, see_through and prefs.blur, window_radius);
        };
        for (a.hosts.items) |h| h.workspace.refreshProgramBgs();
        a.redrawAll();
        // Sharp gaps may have been switched: what the desktop blurs is said again.
        a.frost();
        if (a.overview.shown()) a.overview.widget().queueDraw();
    }

    /// Shows or hides the window's close, minimize and maximize buttons, for a desktop that
    /// has its own ways to do those. The corner is then only the sidebar's button, and what
    /// makes room for the corner follows.
    pub fn windowButtonsChanged(a: *App) void {
        a.corner_controls.setVisible(@intFromBool(settings.current.window_buttons));
        a.cornerChanged();
    }

    pub fn headersChanged(a: *App) void {
        @import("../ui/workspace.zig").show_headers = settings.current.show_headers;
        for (a.hosts.items) |h| h.workspace.headersChanged();
        a.overview.headersChanged();
        a.markHeaders();
    }

    /// Without title rows, nothing makes room for the corner, so the panes start below it.
    fn markHeaders(a: *App) void {
        const w = a.window.as(gtk.Widget);
        if (settings.current.show_headers) w.removeCssClass("no-headers") else w.addCssClass("no-headers");
    }

    /// Applies the terminal options: padding, blink speed, palette, and the rest that redraw.
    pub fn terminalChanged(a: *App) void {
        termview.pad_x = settings.current.pad_x;
        termview.pad_y = settings.current.pad_y;
        // The cursor's blink starts over at the new interval the next time it's drawn.
        termview.blinkReset();
        // Each option does only its own work: the made-up palette recolors the terminals; padding,
        // ligatures and smoothing set each pane's text up again, which also refits it; and the
        // rest (faces, colors) only draws again, since rows are cached by those options. None of
        // them changes the font itself.
        if (a.applied_extended != settings.current.extended_palette) {
            a.applied_extended = settings.current.extended_palette;
            for (a.hosts.items) |h| {
                var it = h.server.streams.valueIterator();
                while (it.next()) |st| st.*.hostColorsChanged();
            }
        }
        if (!std.meta.eql(a.applied_text, TextSetup.now())) a.metricsChanged();
        a.redrawAll();
    }

    /// The options a pane's text setup depends on, besides the font.
    const TextSetup = struct {
        pad_x: f64 = 0,
        pad_y: f64 = 0,
        ligatures: bool = true,
        smoothing: bool = true,

        fn now() TextSetup {
            const st = &settings.current;
            return .{ .pad_x = st.pad_x, .pad_y = st.pad_y, .ligatures = st.ligatures, .smoothing = st.font_smoothing };
        }
    };

    /// How text is set up in each pane changed, so every pane measures and refits, once.
    fn metricsChanged(a: *App) void {
        a.applied_text = TextSetup.now();
        for (a.hosts.items) |h| h.workspace.fontChanged();
    }

    /// Draws every pane again, for options that change how rows look but not their size.
    pub fn redrawAllPub(a: *App) void {
        a.redrawAll();
    }

    pub fn redrawAll(a: *App) void {
        for (a.hosts.items) |h| h.workspace.redraw();
        a.refreshRows();
    }

    fn newWindowIn(a: *App, session_id: []const u8) void {
        // The sidebar lists every host's sessions, so the session may be on another host than
        // the one shown. Asked of the shown host, its server knows no such session.
        if (a.hostOfSession(session_id)) |h| a.selectHost(h);
        const s = a.server orelse return;
        a.auto_picked = false;
        setSlot(&a.session_id, session_id);
        setSlot(&a.window_id, null); // follow the new active window
        s.newWindow(session_id);
    }

    fn toggleSession(a: *App, session_id: []const u8) void {
        if (a.collapsed.fetchRemove(session_id)) |e| {
            gpa.free(e.key);
        } else {
            const key = gpa.dupe(u8, session_id) catch return;
            a.collapsed.put(gpa, key, {}) catch gpa.free(key);
        }
        a.rebuildSidebar();
    }

    fn promptPrev(a: *App) void {
        if (a.workspace) |ws| if (ws.focusedView()) |tv| tv.jumpPrompt(-1);
    }

    fn promptNext(a: *App) void {
        if (a.workspace) |ws| if (ws.focusedView()) |tv| tv.jumpPrompt(1);
    }

    fn toggleSidebar(a: *App) void {
        a.split.setShowSidebar(@intFromBool(a.split.getShowSidebar() == 0));
    }

    fn toggleOverview(a: *App) void {
        if (!settings.current.overview and !a.overview.shown()) return;
        a.overview.toggle();
    }

    pub fn viewsChanged(a: *App) void {
        a.fillSidebarMenu();
        const st = &settings.current;
        a.board_button.as(gtk.Widget).setVisible(@intFromBool(st.agent_board));
        a.overview_button.setVisible(@intFromBool(st.overview));
        if (!st.agent_board and a.board.shown()) a.showBoard(false);
        if (!st.overview) a.overview.hideNow();
    }

    /// The tab the window shows now.
    pub const Tab = struct { host: *Host, session_id: []const u8, window_id: []const u8 };

    pub fn shownTab(a: *App) ?Tab {
        const h = a.current orelse return null;
        const sid = a.session_id orelse return null;
        const w = a.shownWindow() orelse return null;
        return .{ .host = h, .session_id = sid, .window_id = w.id };
    }

    /// Shows a tab of any session on any host, as picking its row in the sidebar does.
    pub fn openTab(a: *App, h: *Host, session_id: []const u8, window_id: []const u8) void {
        a.selectHost(h);
        a.auto_picked = false;
        setSlot(&a.session_id, session_id);
        setSlot(&a.window_id, window_id);
        if (a.server) |s| s.focusWindow(session_id, window_id);
        a.showSelected();
    }

    /// The window stops drawing a background of its own, or draws it again (Settings >
    /// Effects > Window background). Without it only the cards show: the panes, the sidebar
    /// and the board, with the desktop between them. The window's corner goes with it, having
    /// nothing left to sit on, so the sidebar is shown and hidden by its key. `applyLook`
    /// calls this, and goes on to style what is left.
    fn setBare(a: *App, on: bool) void {
        if (a.bare == on) return;
        a.bare = on;
        const w = a.window.as(gtk.Widget);
        if (on) w.addCssClass("bare") else w.removeCssClass("bare");
        a.corner.setVisible(@intFromBool(!on));
        sidebar_slide.from_under = on;
        a.side_slide.queueAllocate();
        a.overview.bareChanged();
        a.cornerChanged();
        a.frost();
    }

    /// The sidebar's card as a part for the desktop to blur behind: as much of it as has come
    /// out from under the panes, or nothing while it is hidden.
    pub fn sidebarFrost(a: *App) ?wayland.Part {
        const win = a.window.as(gtk.Widget);
        var dx: f64 = 0;
        var dy: f64 = 0;
        a.window.as(gtk.Native).getSurfaceTransform(&dx, &dy);
        var at: graphene.Rect = undefined;
        var room: graphene.Rect = undefined;
        if (a.side_root.getMapped() == 0 or a.side_card.computeBounds(win, &at) == 0 or a.side_root.computeBounds(win, &room) == 0) return null;
        const x0 = @max(at.f_origin.f_x, room.f_origin.f_x);
        const x1 = @min(at.f_origin.f_x + at.f_size.f_width, room.f_origin.f_x + room.f_size.f_width);
        if (x1 <= x0) return null;
        const whole = x1 - x0 >= at.f_size.f_width;
        return .{ .x = x0 + dx, .y = at.f_origin.f_y + dy, .w = x1 - x0, .h = at.f_size.f_height, .radius = if (whole and !settings.current.tight) 11 else 0 };
    }

    /// With sharp gaps asked for and no window background, has the desktop blur only what is
    /// behind the cards on screen: the panes', the sidebar's while it shows, or the board. A
    /// desktop that blurs all of a see-through window otherwise blurs the room between the
    /// cards too. Called as the cards are drawn, so what is blurred moves with them; the
    /// overview names its tabs itself while it is open.
    ///
    /// It is a setting, and off unless asked for, because of what it costs on Hyprland 0.57:
    /// for a window that names what to blur, every update of the window, however small, has
    /// Hyprland draw all of it again (its `BackgroundEffect.cpp` damages the whole surface on
    /// each commit). Measured on this window that was three times the GPU for a second of
    /// animation, and naming the parts only while they are still, which avoids it, shows as
    /// the blur between the cards coming and going.
    pub fn frost(a: *App) void {
        if (builtin.os.tag != .linux) return;
        const surface = a.window.as(gtk.Native).getSurface() orelse return;
        if (!a.bare or !settings.current.sharp_gaps) {
            if (a.frosting) wayland.blurAsUsual(surface);
            a.frosting = false;
            return;
        }
        if (a.overview.shown()) return;
        const win = a.window.as(gtk.Widget);
        var dx: f64 = 0;
        var dy: f64 = 0;
        a.window.as(gtk.Native).getSurfaceTransform(&dx, &dy);
        const parts = &a.frost_now;
        parts.clearRetainingCapacity();
        var at: graphene.Rect = undefined;
        if (a.board.shown()) {
            if (a.card.computeBounds(win, &at) != 0) parts.append(gpa, .{ .x = at.f_origin.f_x + dx, .y = at.f_origin.f_y + dy, .w = at.f_size.f_width, .h = at.f_size.f_height }) catch return;
        } else if (a.workspace) |ws| ws.frostParts(win, dx, dy, parts);
        if (a.sidebarFrost()) |part| parts.append(gpa, part) catch return;
        if (a.frosting and a.frost_said == wayland.said and std.mem.eql(u8, std.mem.sliceAsBytes(parts.items), std.mem.sliceAsBytes(a.frost_sent.items))) return;
        wayland.blurParts(surface, parts.items);
        a.frosting = true;
        a.frost_said = wayland.said;
        std.mem.swap(std.ArrayList(wayland.Part), &a.frost_now, &a.frost_sent);
    }

    fn changeServer(a: *App) void {
        a.stack.setVisibleChildName("connect");
    }
};

/// Shows Renux's icon for its windows: from the installed icons, or from the build's when run
/// from zig-out. On a Mac, where it's only built for development, it sets the Dock icon too.
fn useAppIcon() void {
    // Installed apps live in PREFIX/bin with their icons in PREFIX/share, zig-out included.
    var exe_buf: [4096]u8 = undefined;
    const n = std.process.executableDirPath(@import("../main.zig").io, &exe_buf) catch return;
    var dir_buf: [4200]u8 = undefined;
    const data_dir = std.fmt.bufPrint(&dir_buf, "{s}/../share", .{exe_buf[0..n]}) catch return;
    const icons_dir = std.fmt.allocPrintSentinel(gpa, "{s}/icons", .{data_dir}, 0) catch return;
    defer gpa.free(icons_dir);
    gtk.IconTheme.getForDisplay(gdk.Display.getDefault().?).addSearchPath(icons_dir.ptr);
    gtk.Window.setDefaultIconName("dev.renux");
    if (builtin.os.tag == .macos) {
        const png = std.fmt.allocPrintSentinel(gpa, "{s}/icons/hicolor/512x512/apps/dev.renux.png", .{data_dir}, 0) catch return;
        defer gpa.free(png);
        @import("../platform/macos.zig").setDockIcon(png);
    }
}

var mode_app: ?*App = null;

/// The pane that has the window's one cursor: the one with the keyboard, while panes show.
fn cursorPane() ?*termview.TermView {
    const a = mode_app orelse return null;
    if (a.board.shown() or a.overview.shown()) return null;
    const ws = a.workspace orelse return null;
    return ws.focusedView();
}

/// A pane drew: if it has the window's cursor, the cursor layer follows it.
/// The window's own panes were drawn: what the desktop blurs follows them.
fn panesDrawn(ws: *@import("../ui/workspace.zig").Workspace) void {
    const a = mode_app orelse return;
    if (a.workspace == ws) a.frost();
}

fn paneDrawn(v: *termview.TermView) void {
    const a = mode_app orelse return;
    if (cursorPane() != v) return;
    a.cursor_layer.queueDraw();
}

/// A custom shader that can't be used says why, once, rather than the panes quietly not
/// changing.
fn shaderError(message: []const u8) void {
    const a = mode_app orelse return;
    const z = gpa.dupeSentinel(u8, message, 0) catch return;
    defer gpa.free(z);
    a.toastText(z);
}

/// Whether $RENUX_OPEN's tab has been shown.
var open_done = false;
/// The font size Renux started with, which client.font.reset goes back to.
var start_font_size: c_int = 0;

/// Shows the start of a key sequence, such as "ctrl+a …", until it's finished.
/// Fills the hint panel with what each key does next, in columns, or hides it.
fn showHints(a: *App, items: []const termview.Hint) void {
    const w = a.hints.as(gtk.Widget);
    // Hiding keeps the keys it showed while it fades out; they go when it's next filled.
    if (items.len == 0 or !settings.current.key_hints) return w.removeCssClass("shown");
    while (w.getFirstChild()) |c| a.hints.remove(c);
    const grid = gtk.Grid.new();
    grid.setColumnSpacing(10);
    grid.setRowSpacing(5);
    const per_col: usize = @max(6, (items.len + 2) / 3);
    for (items, 0..) |h, i| {
        const col: c_int = @intCast((i / per_col) * 3);
        const row: c_int = @intCast(i % per_col);
        var kbuf: [48]u8 = undefined;
        const key = gtk.Label.new(prettyKey(&kbuf, h.key).ptr);
        key.as(gtk.Widget).addCssClass("hint-key");
        key.setXalign(1);
        grid.attach(key.as(gtk.Widget), col, row, 1, 1);
        var dbuf: [96]u8 = undefined;
        const desc = gtk.Label.new(describeAction(a, &dbuf, h.action, h.args, h.more).ptr);
        desc.as(gtk.Widget).addCssClass("hint-desc");
        desc.setXalign(0);
        desc.setEllipsize(.end);
        desc.setMaxWidthChars(22);
        desc.as(gtk.Widget).setMarginEnd(14);
        grid.attach(desc.as(gtk.Widget), col + 1, row, 1, 1);
    }
    a.hints.append(grid.as(gtk.Widget));
    w.addCssClass("shown");
}

/// Groups hints: panes, then tabs, sessions, the rest of the app, and the config's own actions.
fn sortHints(items: []termview.Hint) void {
    const rank = struct {
        fn of(action: []const u8) u8 {
            const order = [_][]const u8{ "pane.split", "pane.focus", "pane.resize", "pane.", "client.tab.", "session.", "client." };
            for (order, 0..) |o, i| if (std.mem.startsWith(u8, action, o)) return @intCast(i);
            return order.len;
        }
        fn less(_: void, x: termview.Hint, y: termview.Hint) bool {
            const rx = of(x.action);
            const ry = of(y.action);
            if (rx != ry) return rx < ry;
            // Plain keys before ones with ctrl or other modifiers.
            const mx = std.mem.indexOfScalar(u8, x.key, '+') != null and !std.mem.startsWith(u8, x.key, "shift+");
            const my = std.mem.indexOfScalar(u8, y.key, '+') != null and !std.mem.startsWith(u8, y.key, "shift+");
            if (mx != my) return !mx;
            return std.mem.lessThan(u8, x.key, y.key);
        }
    };
    std.mem.sort(termview.Hint, items, {}, rank.less);
}

/// A key name as it reads on the keyboard: shift+- is _, shift+n is N, ctrl+a is ⌃A.
pub fn prettyKey(buf: []u8, name: []const u8) [:0]const u8 {
    var rest = name;
    var n: usize = 0;
    var shift = false;
    while (std.mem.indexOfScalar(u8, rest, '+')) |i| {
        if (i == 0 or i + 1 >= rest.len) break;
        const m = rest[0..i];
        if (std.mem.eql(u8, m, "shift")) shift = true else {
            const sym: []const u8 = if (std.mem.eql(u8, m, "ctrl")) "⌃" else if (std.mem.eql(u8, m, "alt")) "⌥" else if (std.mem.eql(u8, m, "super") or std.mem.eql(u8, m, "cmd")) "⌘" else m;
            if (n + sym.len >= buf.len) break;
            @memcpy(buf[n .. n + sym.len], sym);
            n += sym.len;
        }
        rest = rest[i + 1 ..];
    }
    var key = rest;
    var one: [1]u8 = undefined;
    // Shift folds into the character only when it's the sole modifier, so ctrl+shift+n stays ⌃⇧N.
    if (shift and n > 0 and rest.len == 1) {
        if (n + 3 < buf.len) {
            @memcpy(buf[n .. n + 3], "⇧");
            n += 3;
        }
        shift = false;
        one[0] = std.ascii.toUpper(rest[0]);
        key = &one;
    } else if (shift and rest.len == 1) {
        if (std.mem.indexOfScalar(u8, keys.us_unshifted, rest[0])) |k| {
            one[0] = keys.us_shifted[k];
            key = &one;
            shift = false;
        } else if (std.ascii.isLower(rest[0])) {
            one[0] = std.ascii.toUpper(rest[0]);
            key = &one;
            shift = false;
        }
    } else if (n > 0 and rest.len == 1) {
        one[0] = std.ascii.toUpper(rest[0]);
        key = &one;
    }
    if (shift and n + 3 < buf.len) {
        @memcpy(buf[n .. n + 3], "⇧");
        n += 3;
    }
    const k = key[0..@min(key.len, buf.len - n - 1)];
    @memcpy(buf[n .. n + k.len], k);
    buf[n + k.len] = 0;
    return buf[0 .. n + k.len :0];
}

/// What a binding does, in words: the action's title from the config if it has one, otherwise
/// its name made readable, with its arguments, such as "Split right".
pub fn describeAction(a: *App, buf: []u8, action: []const u8, args: ?[]const u8, more: bool) [:0]const u8 {
    if (more) return std.fmt.bufPrintSentinel(buf, "more…", .{}, 0) catch "";
    var title: []const u8 = "";
    if (a.server) |s| for (s.actions) |act| if (std.mem.eql(u8, act.name, action) and act.title.len > 0) {
        title = act.title;
    };
    if (title.len == 0 and std.mem.eql(u8, action, "pane.copy_mode.enter")) title = "Enter copy mode";
    var name_buf: [64]u8 = undefined;
    const known = [_][2][]const u8{
        .{ "pane.split", "Split" },                   .{ "pane.focus", "Focus" },
        .{ "pane.resize", "Resize" },                 .{ "pane.focus_next", "Next pane" },
        .{ "pane.focus_previous", "Previous pane" },  .{ "pane.close", "Close pane" },
        .{ "pane.zoom", "Zoom pane" },                .{ "pane.balance", "Balance panes" },
        .{ "pane.float", "Float or dock" },           .{ "pane.send_key", "Send" },
        .{ "client.tab.new", "New tab" },             .{ "client.tab.next", "Next tab" },
        .{ "client.tab.previous", "Previous tab" },   .{ "client.tab.rename", "Rename tab" },
        .{ "client.tab.close", "Close tab" },         .{ "client.tab.goto", "Tab" },
        .{ "client.find.open", "Find" },              .{ "client.mode.enter", "Mode" },
        .{ "client.config.reload", "Reload config" }, .{ "client.sidebar.toggle", "Sidebar" },
        .{ "client.overview.toggle", "Overview" },    .{ "client.sidebar.activity.toggle", "Activity" },
        .{ "client.palette.toggle", "Commands" },     .{ "client.sidebar.focus", "Sidebar keys" },
        .{ "session.new", "New session" },            .{ "client.board.toggle", "Agent Board" },
        .{ "session.switch", "Switch session" },      .{ "session.rename", "Rename session" },
        .{ "session.next", "Next session" },          .{ "session.previous", "Previous session" },
    };
    if (title.len == 0) for (known) |k| if (std.mem.eql(u8, k[0], action)) {
        title = k[1];
    };
    if (title.len == 0) {
        // pane.focus_next reads "Focus next"; the prefix before the first dot is left off.
        const base = if (std.mem.indexOfScalar(u8, action, '.')) |i| action[i + 1 ..] else action;
        const n = @min(base.len, name_buf.len);
        for (base[0..n], 0..) |c, i| name_buf[i] = if (c == '_' or c == '.') ' ' else c;
        if (n > 0) name_buf[0] = std.ascii.toUpper(name_buf[0]);
        title = name_buf[0..n];
    }
    // The first plain argument, such as a direction, a tab number or a command.
    var extra: []const u8 = "";
    var parsed: ?std.json.Parsed(std.json.Value) = if (args) |t| std.json.parseFromSlice(std.json.Value, gpa, t, .{}) catch null else null;
    defer if (parsed) |*p| p.deinit();
    var num_buf: [24]u8 = undefined;
    var cmd_buf: [64]u8 = undefined;
    if (parsed) |p| if (p.value == .object) {
        for ([_][]const u8{ "direction", "name", "key", "index", "command" }) |k| {
            const v = p.value.object.get(k) orelse continue;
            extra = switch (v) {
                .string => |t| t,
                .integer => |i| std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch "",
                .array => |arr| blk: {
                    // A command reads whole, such as "lodestar settings".
                    var n: usize = 0;
                    for (arr.items) |item| if (item == .string) {
                        const sep: usize = if (n > 0) 1 else 0;
                        if (n + sep + item.string.len > cmd_buf.len) break;
                        if (sep == 1) cmd_buf[n] = ' ';
                        @memcpy(cmd_buf[n + sep .. n + sep + item.string.len], item.string);
                        n += sep + item.string.len;
                    };
                    break :blk cmd_buf[0..n];
                },
                else => "",
            };
            if (extra.len > 0) break;
        }
    };
    if (extra.len == 0) return std.fmt.bufPrintSentinel(buf, "{s}", .{title}, 0) catch "";
    return std.fmt.bufPrintSentinel(buf, "{s} {s}", .{ title, extra }, 0) catch "";
}

fn chordChanged(pending: []const u8) void {
    const a = mode_app orelse return;
    var items: std.ArrayList(termview.Hint) = .empty;
    defer items.deinit(gpa);
    if (a.server) |s| termview.nextKeys(s.keyBindings(), &items);
    sortHints(items.items);
    showHints(a, items.items);
    if (pending.len == 0) {
        modeChanged();
        return;
    }
    var buf: [200]u8 = undefined;
    const text = std.fmt.bufPrintSentinel(&buf, "{s} …", .{pending}, 0) catch return;
    a.mode_chip.setText(text.ptr);
    a.mode_chip.as(gtk.Widget).addCssClass("shown");
}

fn freeData(data: ?*anyopaque) callconv(.c) void {
    const p: [*:0]u8 = @ptrCast(data orelse return);
    gpa.free(std.mem.span(p));
}

fn modeChanged() void {
    const a = mode_app orelse return;
    if (a.workspace) |ws| if (ws.focusedView()) |tv| {
        var copy_buf: [1200]u8 = undefined;
        if (@import("../terminal/copyview.zig").status(tv, &copy_buf)) |text| {
            a.mode_chip.setText(text.ptr);
            a.mode_chip.as(gtk.Widget).addCssClass("shown");
            showHints(a, &.{});
            return;
        }
    };
    const mode = termview.keyMode();
    if (mode.len == 0) {
        a.mode_chip.as(gtk.Widget).removeCssClass("shown");
        showHints(a, &.{});
        return;
    }
    // A key mode's own keys, such as h j k l to resize.
    var items: std.ArrayList(termview.Hint) = .empty;
    defer items.deinit(gpa);
    if (a.server) |s| for (s.modeBindings()) |b| if (std.mem.eql(u8, b.mode, mode)) {
        items.append(gpa, .{ .key = b.keys, .action = b.action, .args = b.args, .more = false }) catch break;
    };
    showHints(a, items.items);
    var buf: [96]u8 = undefined;
    var upper: [32]u8 = undefined;
    const n = @min(mode.len, upper.len);
    for (mode[0..n], 0..) |ch, i| upper[i] = std.ascii.toUpper(ch);
    const text = std.fmt.bufPrintSentinel(&buf, "{s} · Esc to leave", .{upper[0..n]}, 0) catch return;
    a.mode_chip.setText(text.ptr);
    a.mode_chip.as(gtk.Widget).addCssClass("shown");
}

const SplitOf = struct { id: []const u8, rect: view.Rect, ratio: f64, before: *const view.Node, after: *const view.Node };

/// The ratio last asked of a split, for key repeats that come faster than the server's update.
var last_split: [64]u8 = undefined;
var last_split_len: usize = 0;
var last_ratio: f64 = 0;
var last_ratio_at: i64 = 0;

fn contains(n: *const view.Node, block: []const u8) bool {
    return switch (n.*) {
        .leaf => |l| std.mem.eql(u8, l.block_id, block),
        .split => |sp| contains(sp.before, block) or contains(sp.after, block),
    };
}

/// The innermost split around `block` that divides the way asked.
fn nearestSplit(n: *const view.Node, block: []const u8, horizontal: bool) ?SplitOf {
    switch (n.*) {
        .leaf => return null,
        .split => |sp| {
            const inner = if (contains(sp.before, block)) nearestSplit(sp.before, block, horizontal) else if (contains(sp.after, block)) nearestSplit(sp.after, block, horizontal) else return null;
            if (inner) |x| return x;
            if (sp.horizontal == horizontal) return .{ .id = sp.id, .rect = sp.rect, .ratio = sp.ratio, .before = sp.before, .after = sp.after };
            return null;
        },
    }
}

fn firstLeafOf(n: *const view.Node) []const u8 {
    return switch (n.*) {
        .leaf => |l| l.block_id,
        .split => |sp| firstLeafOf(sp.before),
    };
}

fn leaves(n: *const view.Node) f64 {
    return switch (n.*) {
        .leaf => 1,
        .split => |sp| leaves(sp.before) + leaves(sp.after),
    };
}

fn balanceNode(s: *Server, sid: []const u8, n: *const view.Node) void {
    switch (n.*) {
        .leaf => {},
        .split => |sp| {
            const b = leaves(sp.before);
            s.resizePane(sid, sp.horizontal, firstLeafOf(sp.before), firstLeafOf(sp.after), b / (b + leaves(sp.after)));
            balanceNode(s, sid, sp.before);
            balanceNode(s, sid, sp.after);
        },
    }
}

/// The "•••" menu on a window's row. Its actions carry "session window" as their target.
fn windowMenu(session_id: []const u8, window_id: []const u8) *gio.MenuModel {
    var buf: [512]u8 = undefined;
    const target = std.fmt.bufPrintSentinel(&buf, "{s} {s}", .{ session_id, window_id }, 0) catch "";
    const menu = gio.Menu.new();
    inline for (.{ .{ "Rename…", "app.rename-window" }, .{ "Close window", "app.close-window" } }) |e| {
        const item = gio.MenuItem.new(e[0], null);
        item.setActionAndTargetValue(e[1], glib.Variant.newString(target.ptr));
        menu.appendItem(item);
    }
    return menu.as(gio.MenuModel);
}

fn sessionMenu(session_id: []const u8) *gio.MenuModel {
    const z = gpa.dupeSentinel(u8, session_id, 0) catch return gio.Menu.new().as(gio.MenuModel);
    defer gpa.free(z);
    const menu = gio.Menu.new();
    inline for (.{ .{ "New Window Here", "app.new-window-in" }, .{ "Show or Hide Windows", "app.toggle-session" }, .{ "Rename…", "app.rename-session" }, .{ "Move Up", "app.move-session-up" }, .{ "Move Down", "app.move-session-down" }, .{ "Delete Session", "app.delete-session" } }) |e| {
        const item = gio.MenuItem.new(e[0], null);
        item.setActionAndTargetValue(e[1], glib.Variant.newString(z.ptr));
        menu.appendItem(item);
    }
    return menu.as(gio.MenuModel);
}

/// Makes a second click on a menu's button close the menu and leave it closed. The press of
/// that click lands outside the menu, which closes it; the release then counted as a fresh
/// click on the button and opened it again. A menu that closed a moment ago stays closed.
pub fn steadyMenu(button: *gtk.MenuButton) void {
    _ = gobject.Object.signals.notify.connect(button, ?*anyopaque, &menuToggled, null, .{ .detail = "active" });
}

fn menuToggled(button: *gtk.MenuButton, _: *gobject.ParamSpec, _: ?*anyopaque) callconv(.c) void {
    const obj = button.as(gobject.Object);
    const now: usize = @intCast(@divTrunc(glib.getMonotonicTime(), 1000));
    if (button.getActive() == 0) {
        obj.setData("renux-menu-closed", @ptrFromInt(now + 1));
        return;
    }
    const closed = @intFromPtr(obj.getData("renux-menu-closed"));
    if (closed != 0 and now + 1 -| closed < 350) button.setActive(0);
}

fn menuButton(model: *gio.MenuModel, tooltip: [:0]const u8) *gtk.MenuButton {
    const button = gtk.MenuButton.new();
    steadyMenu(button);
    button.setChild(icons.image(.more, 16));
    button.setMenuModel(model);
    button.as(gtk.Widget).setTooltipText(tooltip.ptr);
    button.as(gtk.Widget).addCssClass("icon-button");
    button.as(gtk.Widget).addCssClass("flat");
    button.as(gtk.Widget).setValign(.center);
    return button;
}

/// The tile for a window's row: its focused pane's program.
fn rowTile(s: *Server, w: *const view.Window) *gtk.Widget {
    const block = w.focused_block_id orelse (if (w.layers.len > 0 and w.layers[0].blocks.len > 0) w.layers[0].blocks[0].id else "");
    var ids: [64][]const u8 = undefined;
    var n: usize = 0;
    for (w.layers) |l| for (l.blocks) |b| if (n < ids.len) {
        ids[n] = b.id;
        n += 1;
    };
    return @import("../icons/blockicon.zig").createFor(s, block, ids[0..n], 16);
}

/// A window's name as its row and tab show it.
pub fn windowLabel(h: *Host, buf: []u8, w: *const view.Window, v: *const view.SessionView) [:0]const u8 {
    return App.rowTitle(h, buf, w, v);
}

/// "file://host/Users/me/My%20Code" as "/Users/me/My Code".
fn folderPath(buf: []u8, uri: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return uri;
    const rest = uri["file://".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "";
    const encoded = rest[slash..];
    var n: usize = 0;
    var i: usize = 0;
    while (i < encoded.len and n < buf.len) : (n += 1) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            buf[n] = std.fmt.parseInt(u8, encoded[i + 1 .. i + 3], 16) catch encoded[i];
            i += 3;
        } else {
            buf[n] = encoded[i];
            i += 1;
        }
    }
    return buf[0..n];
}

fn windowTitle(buf: []u8, w: *const view.Window, v: *const view.SessionView) [:0]const u8 {
    if (w.title()) |t| return std.fmt.bufPrintSentinel(buf, "{s}", .{t}, 0) catch "Window";
    // Rex generated the label, so the first pane's says more.
    for (w.layers) |l| for (l.blocks) |b| if (b.label.len > 0) {
        return std.fmt.bufPrintSentinel(buf, "{s}", .{b.label}, 0) catch "Window";
    };
    for (v.windows, 0..) |*other, i| if (other == w) {
        return std.fmt.bufPrintSentinel(buf, "Window {d}", .{i + 1}, 0) catch "Window";
    };
    return "Window";
}

/// A program as rows and tabs name it: "-zsh" and "node/server.js" are "zsh" and "node".
const programName = @import("../icons/programs.zig").programName;

/// A typed server address as a URL; user@host means SSH, other bare addresses mean HTTP.
/// The caller frees it.
fn normalizeUrl(typed: []const u8) ?[]u8 {
    return @import("../rex/ssh.zig").normalizeUrl(gpa, typed) catch null;
}

fn eqlOpt(a: ?[]const u8, b: []const u8) bool {
    return if (a) |x| std.mem.eql(u8, x, b) else false;
}

fn setSlot(slot: *?[]u8, value: ?[]const u8) void {
    if (slot.*) |old| gpa.free(old);
    slot.* = if (value) |v| gpa.dupe(u8, v) catch null else null;
}

// Development: SIGUSR1 saves a picture of the window to $RENUX_SHOT, since macOS won't let a
// terminal capture another app's window without asking.

var shot_app: ?*App = null;
var updates_app: ?*App = null;

fn updateKnown() void {
    if (updates_app) |a| a.announceUpdate();
}

fn installShotHook(a: *App) void {
    shot_app = a;
    if (std.c.getenv("RENUX_SHOT") != null) _ = @import("glibunix").signalAdd(@backingInt(std.posix.SIG.USR1), &takeShot, null);
    if (std.c.getenv("RENUX_SCRIPT") != null) _ = @import("glibunix").signalAdd(@backingInt(std.posix.SIG.USR2), &runScript, null);
}

fn scriptClipboard(source: ?*gobject.Object, result: *gio.AsyncResult, _: ?*anyopaque) callconv(.c) void {
    const clipboard: *gdk.Clipboard = @ptrCast(source orelse return);
    const text = clipboard.readTextFinish(result, null) orelse return;
    defer glib.free(text);
    std.log.info("clipboard: [{s}]", .{std.mem.span(text)});
}

/// Development: SIGUSR2 runs the commands in $RENUX_SCRIPT against the focused pane, so
/// selection and find can be checked without a mouse. One command per line:
/// `find TEXT`, `select X1 Y1 X2 Y2`, `word X Y`, `copy`, `clipboard`, `copy-state`, `type TEXT`.
fn runScript(_: ?*anyopaque) callconv(.c) c_int {
    const a = shot_app orelse return 1;
    const path = std.c.getenv("RENUX_SCRIPT") orelse return 1;
    var contents: [*]u8 = undefined;
    var len: usize = 0;
    if (glib.fileGetContents(path, &contents, &len, null) == 0) return 1;
    defer glib.free(contents);
    const ws = a.workspace orelse return 1;
    var lines = std.mem.splitScalar(u8, contents[0..len], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = it.next() orelse continue;
        const rest = std.mem.trim(u8, line[cmd.len..], " ");
        // App actions don't need a pane.
        if (std.mem.eql(u8, cmd, "rex")) {
            // A Rex action, optionally with JSON arguments: rex client.mode.enter {"name":"resize"}
            const name = it.next() orelse continue;
            const args_text = std.mem.trim(u8, rest[name.len..], " ");
            const parsed = if (args_text.len > 0) std.json.parseFromSlice(@import("../util/json.zig").Value, gpa, args_text, .{}) catch continue else null;
            defer if (parsed) |p| p.deinit();
            if (a.current) |h| _ = App.perform(h, name, if (parsed) |p| p.value else null, null);
            continue;
        }
        if (std.mem.eql(u8, cmd, "board-keys")) {
            // Keys as the open board hears them: `board-keys l j j enter`.
            const named = [_]struct { []const u8, c_uint, u4 }{ .{ "enter", 0xff0d, 0 }, .{ "escape", 0xff1b, 0 }, .{ "ctrl+d", 'd', keys.ctrl }, .{ "ctrl+u", 'u', keys.ctrl } };
            while (it.next()) |word| {
                var keyval: c_uint = word[0];
                var mods: u4 = 0;
                for (named) |n| if (std.mem.eql(u8, n[0], word)) {
                    keyval = n[1];
                    mods = n[2];
                };
                _ = a.board.handleKey(keyval, mods);
            }
            continue;
        }
        if (std.mem.eql(u8, cmd, "sidebar-keys")) {
            // The keyboard in the sidebar: `sidebar-keys` sends it there, and each word after
            // is a key pressed there, such as `sidebar-keys j j ctrl+d enter`.
            // `sidebar-keys where` only says where the keyboard is.
            if (std.mem.eql(u8, rest, "where")) {
                if (a.sidebarCursor()) |at| std.log.info("sidebar cursor on row {d}", .{at}) else std.log.info("sidebar cursor: none, the keyboard is elsewhere", .{});
                continue;
            }
            if (a.sidebarCursor() == null) a.focusSidebar();
            const named = [_]struct { []const u8, c_uint, u4 }{ .{ "enter", 0xff0d, 0 }, .{ "escape", 0xff1b, 0 }, .{ "ctrl+d", 'd', keys.ctrl }, .{ "ctrl+u", 'u', keys.ctrl } };
            while (it.next()) |word| {
                var keyval: c_uint = word[0];
                var mods: u4 = 0;
                for (named) |n| if (std.mem.eql(u8, n[0], word)) {
                    keyval = n[1];
                    mods = n[2];
                };
                _ = a.sidebarKey(keyval, mods);
            }
            if (a.sidebarCursor()) |at| std.log.info("sidebar cursor on row {d}", .{at});
            continue;
        }
        if (std.mem.eql(u8, cmd, "session-drag")) {
            // Dragging a session in the sidebar without a mouse: `session-drag 1 80` takes hold
            // of the second session's heading and moves it 80 down, `session-drag move 120`
            // moves it on, and `session-drag drop` lets go.
            const what = it.next() orelse continue;
            if (std.mem.eql(u8, what, "drop")) {
                a.session_dragging = false;
                reorder.drop();
            } else if (std.mem.eql(u8, what, "move")) {
                reorder.update(std.fmt.parseFloat(f64, it.next() orelse "0") catch 0);
            } else {
                var nth = std.fmt.parseInt(usize, what, 10) catch continue;
                var child = a.sidebar.as(gtk.Widget).getFirstChild();
                while (child) |c| : (child = c.getNextSibling()) {
                    if (c.hasCssClass("session-row") == 0) continue;
                    if (nth > 0) {
                        nth -= 1;
                        continue;
                    }
                    a.session_grab_y = 8;
                    if (a.startSessionDrag(c)) {
                        a.session_dragging = true;
                        reorder.update(std.fmt.parseFloat(f64, it.next() orelse "0") catch 0);
                    }
                    break;
                }
            }
            continue;
        }
        if (std.mem.eql(u8, cmd, "chip-drag")) {
            // Carrying a minimized pane's chip without a mouse: `chip-drag 1 700 40` takes hold
            // of the second chip by its middle and carries it to that point of the panes' area,
            // `chip-drag move 300 500` carries it on, and `chip-drag drop` lets go.
            const what = it.next() orelse continue;
            if (std.mem.eql(u8, what, "report")) {
                ws.chipReport();
                continue;
            }
            if (std.mem.eql(u8, what, "drop")) {
                ws.simulateChipDrop();
                continue;
            }
            const moving = std.mem.eql(u8, what, "move");
            const x = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
            const y = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
            if (moving) ws.simulateChipMove(x, y) else ws.simulateChipCarry(std.fmt.parseInt(usize, what, 10) catch continue, x, y);
            continue;
        }
        if (std.mem.eql(u8, cmd, "overview-step")) {
            // The overview's motion by hand, for a picture part-way through it: `overview-step
            // 120` stops its clock and moves it on 120 ms, and `overview-step off` lets it run.
            const by = it.next() orelse continue;
            a.overview.hold(if (std.mem.eql(u8, by, "off")) null else std.fmt.parseFloat(f64, by) catch 0);
            continue;
        }
        if (std.mem.eql(u8, cmd, "overview-key")) {
            // Keys as the open overview hears them: overview-key right enter
            const named = [_]struct { []const u8, c_uint }{ .{ "left", 0xff51 }, .{ "up", 0xff52 }, .{ "right", 0xff53 }, .{ "down", 0xff54 }, .{ "enter", 0xff0d }, .{ "escape", 0xff1b }, .{ "x", 'x' }, .{ "c", 'c' }, .{ "s", 's' } };
            while (it.next()) |name| for (named) |n| {
                if (std.mem.eql(u8, n[0], name)) _ = a.overview.key(n[1], 0);
            };
            continue;
        }
        if (std.mem.eql(u8, cmd, "action")) {
            const name = it.next() orelse continue;
            const z = gpa.dupeSentinel(u8, name, 0) catch continue;
            defer gpa.free(z);
            const param: ?*glib.Variant = if (it.next()) |arg| blk: {
                const za = gpa.dupeSentinel(u8, arg, 0) catch continue;
                defer gpa.free(za);
                break :blk glib.Variant.newString(za.ptr);
            } else if (std.mem.startsWith(u8, name, "pane-")) blk: {
                const tvp = ws.focusedView() orelse continue;
                break :blk glib.Variant.newString(@ptrCast((gpa.dupeSentinel(u8, tvp.block_id, 0) catch continue).ptr));
            } else null;
            a.app.as(gio.ActionGroup).activateAction(z.ptr, param);
            continue;
        }
        const tv = ws.focusedView() orelse {
            std.log.info("script: no pane for {s}", .{cmd});
            continue;
        };
        const t = tv.term() orelse {
            std.log.info("script: no terminal for {s}", .{cmd});
            continue;
        };
        std.log.info("script: {s}", .{cmd});
        if (std.mem.eql(u8, cmd, "clipboard")) {
            tv.widget().getClipboard().readTextAsync(null, &scriptClipboard, null);
        } else if (std.mem.eql(u8, cmd, "copy-state")) {
            if (tv.copy_mode) |s| std.log.info("copy-state: cursor={d},{d} top={d} kind={s} anchor={any} count={d} search={any} missing={any}", .{ s.mode.cursor.x, s.mode.cursor.y, s.mode.top, @tagName(s.mode.kind), s.mode.anchor, s.mode.count, s.mode.searching, s.mode.not_found }) else std.log.info("copy-state: off", .{});
        } else if (std.mem.eql(u8, cmd, "carry")) {
            const x = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
            const y = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
            ws.simulateCarry(tv.block_id, x, y);
        } else if (std.mem.eql(u8, cmd, "key")) {
            // Presses like "ctrl+a", "shift+-" or "left", one after another.
            var keys_it = std.mem.tokenizeScalar(u8, rest, ' ');
            while (keys_it.next()) |press| {
                var mods: u4 = 0;
                var parts = std.mem.splitScalar(u8, press, '+');
                var last: []const u8 = "";
                while (parts.next()) |part| {
                    if (parts.peek() == null or part.len == 0) {
                        last = if (part.len == 0) "+" else part;
                        break;
                    }
                    const K = @import("../terminal/keys.zig");
                    if (std.mem.eql(u8, part, "ctrl")) mods |= K.ctrl else if (std.mem.eql(u8, part, "shift")) mods |= K.shift else if (std.mem.eql(u8, part, "alt")) mods |= K.alt else if (std.mem.eql(u8, part, "super")) mods |= K.super;
                }
                const named = [_]struct { []const u8, c_uint }{ .{ "left", 0xff51 }, .{ "up", 0xff52 }, .{ "right", 0xff53 }, .{ "down", 0xff54 }, .{ "enter", 0xff0d }, .{ "escape", 0xff1b }, .{ "tab", 0xff09 } };
                var keyval: c_uint = if (last.len == 1) last[0] else 0;
                for (named) |n| if (std.mem.eql(u8, n[0], last)) {
                    keyval = n[1];
                };
                if (keyval == 0) continue;
                const target = (a.workspace orelse ws).focusedView() orelse tv;
                // As a real key goes: the window hears it first, and may keep it.
                switch (a.routeKey(keyval, mods)) {
                    .taken => {},
                    .left => _ = target.handleKey(keyval, mods),
                    .to_pane => {
                        _ = target.widget().grabFocus();
                        _ = target.handleKey(keyval, mods);
                    },
                }
            }
        } else if (std.mem.eql(u8, cmd, "bench")) {
            tv.bench();
        } else if (std.mem.eql(u8, cmd, "benchwin")) {
            benchWindow(a);
        } else if (std.mem.eql(u8, cmd, "drop")) {
            ws.simulateDrop();
        } else if (std.mem.eql(u8, cmd, "peek-key")) {
            // A key in the file peek that is open: peek-key enter | shift-enter | escape | download
            @import("../ui/peek.zig").press(rest);
        } else if (std.mem.eql(u8, cmd, "open-link")) {
            // Ctrl+click on the link at a cell: open-link COL ROW
            const col = std.fmt.parseInt(u16, it.next() orelse "0", 10) catch 0;
            const row = std.fmt.parseInt(u16, it.next() orelse "0", 10) catch 0;
            tv.openLinkAt(col, row);
        } else if (std.mem.eql(u8, cmd, "upload")) {
            // Sends a file as dropping it on a remote pane does: upload /path/to/file
            const sent = gpa.dupeSentinel(u8, rest, 0) catch continue;
            defer gpa.free(sent);
            const file = gio.File.newForPath(sent.ptr);
            defer file.unref();
            _ = tv.upload(&.{file}, false);
        } else if (std.mem.eql(u8, cmd, "sidebar")) {
            if (a.split.getSidebar()) |sb| std.log.info("sidebar was {d} wide (asked {d:.0})", .{ sb.getWidth(), a.split.getMaxSidebarWidth() });
            a.setSidebarWidth(std.fmt.parseFloat(f64, it.next() orelse "250") catch 250);
        } else if (std.mem.eql(u8, cmd, "hovercard")) {
            @import("../ui/hovercard.zig").showLast();
        } else if (std.mem.eql(u8, cmd, "line")) {
            ws.simulateLine();
        } else if (std.mem.eql(u8, cmd, "divider")) {
            const dx = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
            ws.simulateDivider(dx);
        } else if (std.mem.eql(u8, cmd, "commit")) {
            const z = gpa.dupeSentinel(u8, rest, 0) catch continue;
            defer gpa.free(z);
            tv.commitText(z);
        } else if (std.mem.eql(u8, cmd, "menu")) {
            tv.showMenuAt(120, 120);
        } else if (std.mem.eql(u8, cmd, "zoom")) {
            tv.zoomBy(std.fmt.parseFloat(f64, it.next() orelse "0") catch 0);
        } else if (std.mem.eql(u8, cmd, "wheel")) {
            tv.wheelBy(std.fmt.parseFloat(f64, rest) catch 1);
        } else if (std.mem.eql(u8, cmd, "coast")) {
            tv.coastBy(std.fmt.parseFloat(f64, rest) catch 0);
        } else if (std.mem.eql(u8, cmd, "glide-ease")) {
            _ = tv.glide.ease((std.fmt.parseFloat(f64, rest) catch 16) / 1000, tv.cell_h);
        } else if (std.mem.eql(u8, cmd, "pane-shot")) {
            const scale: f32 = @floatCast(termview.shotScale() orelse 1);
            const node = tv.picture(scale) orelse continue;
            defer node.unref();
            const renderer = a.window.as(gtk.Native).getRenderer() orelse continue;
            const z = gpa.dupeSentinel(u8, rest, 0) catch continue;
            defer gpa.free(z);
            const pane = tv.widget();
            var whole: @import("graphene").Rect = .{ .f_origin = .{ .f_x = 0, .f_y = 0 }, .f_size = .{ .f_width = @ceil(@as(f32, @floatFromInt(pane.getWidth())) * scale), .f_height = @ceil(@as(f32, @floatFromInt(pane.getHeight())) * scale) } };
            const texture = renderer.renderTexture(node, &whole);
            defer texture.as(gobject.Object).unref();
            _ = texture.saveToPng(z.ptr);
            std.log.info("pane-shot: glide at {d:.2} of a {d:.0} row", .{ tv.glide.offset, tv.cell_h });
        } else if (std.mem.eql(u8, cmd, "scroll")) {
            const dy = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
            tv.scrollBy(dy);
        } else if (std.mem.eql(u8, cmd, "find")) {
            a.openFind();
            const z = gpa.dupeSentinel(u8, rest, 0) catch continue;
            defer gpa.free(z);
            if (a.focusedFind()) |f| f.type_(z);
        } else if (std.mem.eql(u8, cmd, "close-find")) {
            a.closeFind();
        } else if (std.mem.eql(u8, cmd, "select")) {
            var n: [4]u16 = .{ 0, 0, 0, 0 };
            for (&n) |*v| v.* = std.fmt.parseInt(u16, it.next() orelse "0", 10) catch 0;
            t.selectRange(n[0], n[1], n[2], n[3]);
        } else if (std.mem.eql(u8, cmd, "word")) {
            const x = std.fmt.parseInt(u16, it.next() orelse "0", 10) catch 0;
            const y = std.fmt.parseInt(u16, it.next() orelse "0", 10) catch 0;
            t.selectWord(x, y);
        } else if (std.mem.eql(u8, cmd, "copy")) {
            tv.copySelection(false);
        } else if (std.mem.eql(u8, cmd, "physical-key")) {
            // A key as the keyboard gives it: `physical-key down j` (again while down is a
            // repeat) and `physical-key up j`.
            const dir = it.next() orelse continue;
            const what = it.next() orelse continue;
            const cp = std.unicode.utf8Decode(what[0 .. std.unicode.utf8ByteSequenceLength(what[0]) catch continue]) catch continue;
            // Any number stands for the key on the keyboard, as long as down and up agree.
            const keycode: c_uint = 1000 + @as(c_uint, cp);
            if (std.mem.eql(u8, dir, "down")) tv.sendPress(keys.forChar(cp, 0), keycode) else tv.releaseKey(keycode);
        } else if (std.mem.eql(u8, cmd, "type")) {
            const view_ = std.unicode.Utf8View.init(rest) catch continue;
            var cps = view_.iterator();
            while (cps.nextCodepoint()) |cp| a.server.?.sendKey(tv.session_id, tv.block_id, @import("../terminal/keys.zig").forChar(cp, 0));
            a.server.?.sendKey(tv.session_id, tv.block_id, @import("../terminal/keys.zig").fromGdk(0xff0d, 0, 0).?);
        }
        // The pane the command began in may be gone by now, when the command went to another tab.
        if (a.workspace) |now| if (now.focusedView()) |v| v.widget().queueDraw();
    }
    return 1;
}

/// Development: with RENUX_PERF set, logs each second of drawing: frames shown, the longest
/// gap between frames, and how long Renux spent making a frame.
const FrameLog = struct {
    var start: i64 = 0;
    var last_end: i64 = 0;
    var window_start: i64 = 0;
    var frames: u32 = 0;
    var worst_gap: i64 = 0;
    var work_total: i64 = 0;
    var worst_work: i64 = 0;

    /// Pointer movements since the last line. Each one takes a turn of the frame clock to
    /// deliver, so a pointer crossing the window shows as frames with next to no work in them.
    var moves: u32 = 0;

    fn moved(_: *gtk.EventControllerMotion, _: f64, _: f64, _: ?*anyopaque) callconv(.c) void {
        moves += 1;
    }

    fn watchPointer(win: *gtk.Widget) void {
        const motion = gtk.EventControllerMotion.new();
        motion.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerMotion.signals.motion.connect(motion, ?*anyopaque, &moved, null, .{});
        win.addController(motion.as(gtk.EventController));
    }

    fn watch(clock: *gdk.FrameClock) void {
        // Every frame starts here. The later phases only say when one starts if they run at
        // all, and a handler added to `paint` runs after the painting it was meant to time.
        _ = gdk.FrameClock.signals.before_paint.connect(clock, ?*anyopaque, &began, null, .{});
        _ = gdk.FrameClock.signals.update.connect(clock, ?*anyopaque, &began, null, .{});
        _ = gdk.FrameClock.signals.layout.connect(clock, ?*anyopaque, &began, null, .{});
        _ = gdk.FrameClock.signals.layout.connect(clock, ?*anyopaque, &laidOut, null, .{ .after = true });
        _ = gdk.FrameClock.signals.paint.connect(clock, ?*anyopaque, &began, null, .{});
        _ = gdk.FrameClock.signals.after_paint.connect(clock, ?*anyopaque, &ended, null, .{});
    }

    var counter: i64 = -1;
    var layout_end: i64 = 0;

    fn laidOut(_: *gdk.FrameClock, _: ?*anyopaque) callconv(.c) void {
        layout_end = glib.getMonotonicTime();
    }

    /// GTK skips the phases nothing asked for, so the frame starts at the first one that runs.
    fn began(clock: *gdk.FrameClock, _: ?*anyopaque) callconv(.c) void {
        const c = clock.getFrameCounter();
        if (c == counter) return;
        counter = c;
        start = glib.getMonotonicTime();
        layout_end = start;
    }

    fn ended(clock: *gdk.FrameClock, _: ?*anyopaque) callconv(.c) void {
        const now = glib.getMonotonicTime();
        // A pause of more than half a second starts a new measurement.
        if (now - last_end > 500_000) {
            flush(clock);
            window_start = now;
        } else {
            worst_gap = @max(worst_gap, now - last_end);
        }
        last_end = now;
        frames += 1;
        const work = now - start;
        if (work > 12_000) std.log.info("slow frame: {d:.1} ms, layout {d:.1}, paint {d:.1}", .{
            @as(f64, @floatFromInt(work)) / 1000,
            @as(f64, @floatFromInt(layout_end - start)) / 1000,
            @as(f64, @floatFromInt(now - layout_end)) / 1000,
        });
        work_total += work;
        worst_work = @max(worst_work, work);
        if (now - window_start >= 1_000_000) {
            flush(clock);
            window_start = now;
        }
    }

    fn flush(clock: *gdk.FrameClock) void {
        if (frames > 1) std.log.info("frames: {d} in {d} ms, worst gap {d:.1} ms, work avg {d:.1} ms worst {d:.1} ms, refresh {d:.1} ms, pointer moves {d}, ticking: panes {d} scroll {d} corner {}", .{
            frames,
            @divTrunc(last_end - window_start, 1000),
            @as(f64, @floatFromInt(worst_gap)) / 1000,
            @as(f64, @floatFromInt(@divTrunc(work_total, frames))) / 1000,
            @as(f64, @floatFromInt(worst_work)) / 1000,
            @as(f64, @floatFromInt(refresh(clock))) / 1000,
            moves,
            @import("../ui/workspace.zig").ticking,
            termview.scroll_ticking,
            if (shot_app) |a| a.corner_tick != 0 else false,
        });
        frames = 0;
        moves = 0;
        worst_gap = 0;
        work_total = 0;
        worst_work = 0;
    }

    fn refresh(clock: *gdk.FrameClock) i64 {
        var interval: i64 = 0;
        var presentation: i64 = 0;
        clock.getRefreshInfo(clock.getFrameTime(), &interval, &presentation);
        return interval;
    }
};

/// Development: times a whole-window frame, building the snapshot and rendering it at 2x.
fn benchWindow(a: *App) void {
    const w = a.window.as(gtk.Widget);
    const width: f64 = @floatFromInt(w.getWidth());
    const height: f64 = @floatFromInt(w.getHeight());
    const renderer = a.window.as(gtk.Native).getRenderer() orelse return;
    var snap_us: i64 = 0;
    var render_us: i64 = 0;
    const n = 30;
    for (0..n) |_| {
        const t0 = glib.getMonotonicTime();
        const paintable = gtk.WidgetPaintable.new(w);
        const snap = gtk.Snapshot.new();
        snap.scale(2, 2);
        paintable.as(gdk.Paintable).snapshot(snap.as(gdk.Snapshot), width, height);
        const node = snap.freeToNode() orelse return;
        const t1 = glib.getMonotonicTime();
        const texture = renderer.renderTexture(node, null);
        texture.as(gobject.Object).unref();
        node.unref();
        paintable.as(gobject.Object).unref();
        const t2 = glib.getMonotonicTime();
        snap_us += t1 - t0;
        render_us += t2 - t1;
    }
    std.log.info("benchwin: {d}x{d} at 2x, snapshot {d} us, render {d} us per frame", .{ width, height, @divTrunc(snap_us, n), @divTrunc(render_us, n) });
}

fn takeShot(_: ?*anyopaque) callconv(.c) c_int {
    const a = shot_app orelse return 1;
    const path = std.c.getenv("RENUX_SHOT") orelse return 1;
    const w = a.window.as(gtk.Widget);
    const paintable = gtk.WidgetPaintable.new(w);
    defer paintable.as(gobject.Object).unref();
    const width: f64 = @floatFromInt(w.getWidth());
    const height: f64 = @floatFromInt(w.getHeight());
    const snap = gtk.Snapshot.new();
    // RENUX_SHOT_SCALE=2 saves the picture at twice the size, as a HiDPI screen shows it.
    const scale: f32 = @floatCast(termview.shotScale() orelse 1);
    if (scale != 1) snap.scale(scale, scale);
    // On screen the window sits some way into its surface, past its shadow, and that is rarely
    // a whole number of pixels. The picture starts the same part of a pixel in, so that what
    // is lined up with the screen's pixels is lined up with the picture's too.
    var into_x: f64 = 0;
    var into_y: f64 = 0;
    a.window.as(gtk.Native).getSurfaceTransform(&into_x, &into_y);
    snap.translate(&.{ .f_x = @floatCast(@mod(into_x * scale, 1) / scale), .f_y = @floatCast(@mod(into_y * scale, 1) / scale) });
    paintable.as(gdk.Paintable).snapshot(snap.as(gdk.Snapshot), width, height);
    const node = snap.freeToNode() orelse return 1;
    defer node.unref();
    const renderer = a.window.as(gtk.Native).getRenderer() orelse return 1;
    // The picture starts at the corner, not at the drawing's own edge, which would take the
    // part-pixel offset straight back out.
    var whole: @import("graphene").Rect = .{ .f_origin = .{ .f_x = 0, .f_y = 0 }, .f_size = .{ .f_width = @ceil(@as(f32, @floatCast(width)) * scale) + 1, .f_height = @ceil(@as(f32, @floatCast(height)) * scale) + 1 } };
    const texture = renderer.renderTexture(node, &whole);
    defer texture.as(gobject.Object).unref();
    _ = texture.saveToPng(path);
    // The settings page showing, whole, with what is scrolled out of sight.
    if (@import("../settings/settings_window.zig").wholePage()) |pw| {
        const pp = gtk.WidgetPaintable.new(pw);
        defer pp.as(gobject.Object).unref();
        const ps = gtk.Snapshot.new();
        pp.as(gdk.Paintable).snapshot(ps.as(gdk.Snapshot), @floatFromInt(pw.getWidth()), @floatFromInt(pw.getHeight()));
        if (ps.freeToNode()) |pn| {
            defer pn.unref();
            const pt = renderer.renderTexture(pn, null);
            defer pt.as(gobject.Object).unref();
            var pbuf: [1024]u8 = undefined;
            if (std.fmt.bufPrintSentinel(&pbuf, "{s}.page.png", .{std.mem.span(path)}, 0)) |page_path| _ = pt.saveToPng(page_path.ptr) else |_| {}
        }
    }
    // A hover card is a window of its own, so it gets a picture of its own beside the first.
    if (@import("../ui/hovercard.zig").visibleCard() orelse @import("../ui/peek.zig").visible()) |cw| {
        const cp = gtk.WidgetPaintable.new(cw);
        defer cp.as(gobject.Object).unref();
        const cs = gtk.Snapshot.new();
        cp.as(gdk.Paintable).snapshot(cs.as(gdk.Snapshot), @floatFromInt(cw.getWidth()), @floatFromInt(cw.getHeight()));
        if (cs.freeToNode()) |cn| {
            defer cn.unref();
            const ct = renderer.renderTexture(cn, null);
            defer ct.as(gobject.Object).unref();
            var pbuf: [1024]u8 = undefined;
            if (std.fmt.bufPrintSentinel(&pbuf, "{s}.card.png", .{std.mem.span(path)}, 0)) |card_path| _ = ct.saveToPng(card_path.ptr) else |_| {}
        }
    }
    return 1;
}
