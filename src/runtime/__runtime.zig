// pub const DO_DEBUG_TRACE: bool = true;
pub const DO_DEBUG_TRACE: bool = false;

pub const DEBUG_STRESS_GC: bool = false;
pub const DEBUG_PRINT_GC_STATS: bool = false;

pub const DEBUG_CLEAR_SCREEN: bool = false;
pub const DEBUG_PRINT_PTR: union(enum) { none, modulo: usize, full_dec } = .{ .modulo = 10_000 };
pub const DEBUG_SKIP_BOOTSTRAP: bool = false or (DO_DEBUG_TRACE and true);

pub const DEBUG_ARRAY_ELEMENTS_TO_PRINT: usize = 3;
pub const DEBUG_PRINT_STACK_ON_EXIT: bool = false or DO_DEBUG_TRACE;

const interning_module = @import("../interning/__interning.zig");
const SymbolsManager = interning_module.SymbolsManager;
const SymbolId = interning_module.SymbolId;
const SymbolArrayMap = interning_module.SymbolArrayMap;

const codegen_module = @import("../frontend/codegen.zig");
const ClassDefinitionPair = codegen_module.ClassDefinitionPair;
const StringLiteralId = codegen_module.StringLiteralId;
const BlockDefinitionId = codegen_module.BlockDefinitionId;
const Bytecode = codegen_module.Bytecode;
const InstructionDecoder = codegen_module.InstructionDecoder;
const Instruction = codegen_module.Instruction;
const ConstantsManager = codegen_module.ConstantsManager;
const ConstantId = codegen_module.ConstantId;
const RelativeConstantId = codegen_module.RelativeConstantId;
const InstructionId = codegen_module.InstructionId;
const compile_class_with_its_parents = codegen_module.compile_class_with_its_parents;
const compile_class = codegen_module.compile_class;
const compile_class_ignoring_parents = codegen_module.compile_class_ignoring_parents;
const allocate_heap_data = codegen_module.allocate_heap_data;
const SourceCodeFiles = codegen_module.SourceCodeFiles;
const InstructionEncoder = codegen_module.InstructionEncoder;
pub const BlockDefinition = codegen_module.BlockDefinition;

pub const vm_object_module = @import("vm_object.zig");
pub const VmObject = vm_object_module.VmObject;
pub const HeapData = vm_object_module.HeapData;
pub const types = vm_object_module.types;
pub const FrameOnHeap = vm_object_module.FrameOnHeap;
pub const OpaqueHeader = vm_object_module.OpaqueHeader;
pub const EmptyHeapSegment = vm_object_module.EmptyHeapSegment;
pub const object_alignment_in_bytes = vm_object_module.object_alignment_in_bytes;
pub const pointer_after = vm_object_module.pointer_after;
pub const slice_after = vm_object_module.slice_after;

const primitives_module = @import("primitives/__primitives.zig");
pub const primitive_methods_module = primitives_module.primitive_methods;
pub const PrimitiveMethodsMap = primitives_module.PrimitiveMethodsMap;
pub const PrimitiveMethodImplementation = primitives_module.PrimitiveMethodImplementation;

pub const class_definition_module = @import("class_definition.zig");
pub const ClassDefinition = class_definition_module.ClassDefinition;
pub const MethodBody = class_definition_module.MethodBody;
pub const MethodDefinition = class_definition_module.MethodDefinition;
pub const FunctionBody = class_definition_module.FunctionBody;

pub const interpreter_module = @import("interpreter.zig");
pub const BuiltinClassDefinitions = interpreter_module.BuiltinClassDefinitions;
pub const Interpreter = interpreter_module.Interpreter;
pub const Statics = interpreter_module.Statics;
pub const Heap = interpreter_module.Heap;
pub const Stack = interpreter_module.Stack;
