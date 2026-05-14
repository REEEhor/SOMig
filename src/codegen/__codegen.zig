pub const bytecode_generator = @import("bytecode_generator.zig");
pub const BytecodeGenerator = bytecode_generator.BytecodeGenerator;
pub const CompileError = bytecode_generator.CompileError;

pub const class_loader = @import("class_loader.zig");
pub const ClassLoader = class_loader.ClassLoader;

pub const lexical_scope_stack = @import("lexical_scope_stack.zig");
pub const LexicalScopeStack = lexical_scope_stack.LexicalScopesStack;

pub const source_code_files = @import("source_code_files.zig");
pub const SourceCodeFiles = source_code_files.SourceCodeFiles;
