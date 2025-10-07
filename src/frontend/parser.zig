// @nice-to-have: When there is an unexpected binary message, it might have been meant
//                as a unary operator. Nice error message would have been nice.
//                Maybe the lexer should lex `+2` correctly.

const lexer = @import("lexer.zig");
const Lexer = lexer.Lexer;

const Parser = struct {
	const Self = @This();
};
