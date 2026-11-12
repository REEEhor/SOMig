# **SOM**ig - a Zig implementation of SOM 

[Simple Object Machine (SOM)](https://som-st.github.io/) is a minimal [Smalltalk](https://en.wikipedia.org/wiki/Smalltalk)-like language, used for the teaching and research of virtual machines.

This repository is an implementation of a virtual machine for SOM in the [Zig programming language](https://ziglang.org/).

**SOMig is my bachelor's thesis**. Click [here](https://hdl.handle.net/10467/184074) to see the paper part of the thesis, its results and reviews (please note that the site can take a minute to load).

---

Mascot of SOMig is a hamster which is biting on the logo of [SOM](https://som-st.github.io/) (a reference to the polish word [chomik](https://pl.wikipedia.org/wiki/Chomik_europejski) for a hamster).


<table>
<tr>
<td valign="top" width="300">
<img width="300" alt="image" src="https://github.com/user-attachments/assets/4523a1ee-c3a9-4968-a5a4-53302b0aa4dc" />
</td>
<td valign="top">

General overview of this VM:

- Traditional frontend: lexing tokens -> parsing into AST -> generate bytecode
  - Note: the bytecode is type-safe, without sacrificing performance nor memory.
  - See `src/bytecode/decoder.zig` for more info.
- Stack-based interpreter
- Mark-sweep garbage collector
- NaN boxing
- Lazy-loading of classes
- Symbol interning
- Calls to 'super' are statically resolved and therefore skip dynamic dispatch at runtime
- In many cases, the call-stack frames are not allocated on the heap of the VM (which is uncommon in other SOM VMs)

</td>
</tr>
</table>

Performance comparison of SOMig against CSOM (SOM VM written in C) and SOM++. SOM++ is the fastest non-jitting SOM VM implementation written in C++:

<p align="center">
  <img width="450" alt="image" src="https://github.com/user-attachments/assets/5336aff3-4b57-479e-a831-22f0efc5f62a" />
</p>

---
THE FOLDERS `Smalltalk/` AND `test/AreWeFastYetCoreLib/` ARE VENDORED FROM [https://github.com/SOM-st/SOM.git](). SEE `thirdparty/` FOR LICENSE AND AUTHORS FILES.
Most of the tests in `test/integration_tests/` are a modified copy integration tests from the SOM repository.

---

# How to build and run

### Requirements: `Zig 0.15.1`
```bash
# Build with optimizations
zig build  -Doptimize=ReleaseFast
```

Run some of the provided examples:
```bash
./somig --recursively-include Smalltalk:examples  --  GameOfLife glider
```
```bash
./somig --recursively-include Smalltalk:examples  --  GameOfLife examples/game-of-life/inputs/glider-gun.txt 0
```
```bash
./somig --recursively-include Smalltalk:examples  --  Calculator
```
```bash
./somig --recursively-include Smalltalk:examples  --  EchoArgs 10 20 hello 30
```

Run all tests: 
```bash
zig build test
```

### Explanation of the interpreter arguments
In general, the structure is as follows:
```bash 
./somig RUNTIME-SETTINGS -- ARGUMENTS-FOR-ENTRY-VM-POINT
```
It will almost always look similar to:
```bash 
./somig -i Smalltalk:someDir -- NameOfEntryPointClass (maybe-other-arguments...)
```

- `RUNTIME-SETTINGS` include:

  - `-i` or `--include DIR1:DIR2:DIR3:...` - paths to directories (separated by `:`) which the runtime should look into when searching for `.som` class definitions (this option also has an alias `-cp` to be compatible with other SOM VMs).
    - This flag is used upon every conventional start of the VM, as the standard library in the `Smalltalk/` directory must be included via `-i Smalltalk`. SOM has a lot of stuff defined in user-land, including definitions of booleans for example.
  
  - `-r`, `-ri`, `-ir`, or `--recursively-include DIR1:DIR2:DIR3:...` same as `--include`, but allows the runtime to search the directories recursively.

  - `--no-color` - do not use ANSI for colored output of errors and warnings.

  - `--no-bs` (*no bootstrapping*) - makes it so that the entrypoint of the program is not the `initialize:` method of class `System` as it complicates the startup. The VM will do the work of this method by itself. This is useful for debugging as it simplifies the execution and makes the call-stack smaller.

  - `--object-stack SIZE` - sets the object-stack's size to `SIZE`. Defaults to `1000`. SOMig has a stack-based interpreter. The operational stack is called object-stack.
  
  - `--frame-stack SIZE` - sets the frame-stack's size to `SIZE`. Defaults to `1000`. The frame-stack is a function callstack in the VM.

- `ARGUMENTS-FOR-ENTRY-VM-POINT` are strings which will be passed into the runtime's entry point, which is by default the `initialize:` method on the class `System` (which be found in `Smalltalk/System.som`). This method expects there to be at least one argument, which is the name of the class to run. Rest of the arguments are then passed into the `run:` method of the entry point class. The class can also only define the `run` method. See the `Smalltalk/System.som` class for more information.

It is also possible to specify the entry point class like this:
```bash
./somig -i Smalltalk path/to/dir/NameOfEntryPointClass.som   (maybe-other-arguments...)
```
which de-sugars to:
```bash
./somig -i Smalltalk:path/to/dir/ -- NameOfEntryPointClass   (maybe-other-arguments...)
```
This 'de-sugaration' is implemented to be compatible with other SOM VM implementations.
