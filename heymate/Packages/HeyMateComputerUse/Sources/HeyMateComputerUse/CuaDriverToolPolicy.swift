//
//  CuaDriverToolPolicy.swift
//  HeyMateComputerUse
//
//  Which Cua tools a HeyMate job may call.
//
//  HeyMate's approval gate is the plan leg: the agent reads and proposes,
//  the user approves, and only the execute leg can change anything. The Cua
//  server is attached to approved legs only, so these lists are not the
//  gate — they are the ceiling inside an approved job.
//
//  Two kinds of tool never reach a job:
//  - anything that changes the driver itself or installs software
//    (`set_config`, `install_ffmpeg`, the cursor theme), because an approved
//    plan to edit a document is not consent to reconfigure the Mac;
//  - the clipboard, in both directions, because it holds whatever the user
//    last copied — often a password — and a job has no business reading or
//    replacing it.
//
//  Tools added in later Cua releases are not listed and are therefore not
//  allowed until someone reviews them here.
//

import Foundation

public enum CuaDriverToolPolicy {

    /// Look, never touch. Safe for a planning pass.
    public static let observationTools: [String] = [
        "list_apps",
        "list_windows",
        "get_window_state",
        "verify_state",
        "get_screen_size",
        "get_desktop_state",
        "get_cursor_position",
        "get_accessibility_tree",
        "zoom",
        "get_browser_state",
        "health_report",
        "check_permissions"
    ]

    /// Acting on apps the approved plan named.
    public static let actionTools: [String] = [
        "launch_app",
        "bring_to_front",
        "set_window_frame",
        "invoke_menu",
        "click",
        "double_click",
        "right_click",
        "drag",
        "type_text",
        "press_key",
        "hotkey",
        "set_value",
        "scroll",
        "move_cursor",
        "page",
        "browser_navigate",
        "browser_click",
        "browser_type",
        "browser_dialog",
        "browser_pointer",
        // The agent cursor is how the user watches a background action
        // happen; leaving it controllable keeps that visible.
        "set_agent_cursor_enabled",
        "set_agent_cursor_motion",
        "get_agent_cursor_state",
        "start_session",
        "get_session",
        "get_session_state",
        "list_sessions",
        "end_session"
    ]

    /// Reviewed and refused. Kept as a list so a reviewer can see the
    /// decision was made, not missed.
    public static let refusedTools: [String] = [
        "clipboard_read",
        "clipboard_write",
        "set_config",
        "install_ffmpeg",
        "set_agent_cursor_theme",
        "kill_app",
        "browser_prepare",
        "browser_set_input_files",
        "browser_download",
        "replay_trajectory",
        "escalate_session",
        "check_for_update"
    ]

    /// Everything an approved execute leg may call.
    public static var approvedLegTools: [String] { observationTools + actionTools }
}
