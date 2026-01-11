pub const RED = "\x1b[31m";
pub const GREEN = "\x1b[32m";
pub const YELLOW = "\x1b[33m";
pub const BOLD = "\x1b[1m";
pub const CYAN = "\x1b[36m";

pub const RED_BG = "\x1b[41m";
pub const FAINT = "\x1b[2m";

pub const ERR = RED ++ BOLD;
pub const WARN = YELLOW ++ BOLD;

pub const RESET = "\x1b[0m";

pub const ERASE_ENTIRE_LINE = "\x1b[2K";
// pub const GO_TO_FIRST_COLUMN = "\x1b[0E";
