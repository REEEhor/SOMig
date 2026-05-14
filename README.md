# **SOM**ig - a Zig implementation of SOM 

[Simple Object Machine (SOM)](https://som-st.github.io/) is a minimal [Smalltalk](https://en.wikipedia.org/wiki/Smalltalk)-like language, used for the teaching and research of virtual machines.

This repository is an implementation of a virtual machine for SOM in the [Zig programming language](https://ziglang.org/).

SOMig is a bachelor's thesis. Click [here](https://gitlab.fit.cvut.cz/rehorja8/paper-part-of-somig) to go to the repository for the paper part of the thesis.

---
THE FOLDERS `Smalltalk/` AND `test/AreWeFastYetCoreLib/` ARE VENDORED FROM [https://github.com/SOM-st/SOM.git](). SEE `thirdparty/` FOR LICENSE AND AUTHORS FILES.

---

## How to build and run

Requirements: **Zig 0.15.1**.
```bash
# Build with optimizations
zig build -Doptimize=ReleaseFast
```

Run example:
```bash
./somig -ir Smalltalk:examples -- GameOfLife glider
```

Run all tests: 
```bash
zig build test
```

### Explanation of the interpreter arguments
In general, the structure is as follows:
```bash 
./somig (RUNTIME-SETTINGS...) -- (ARGUMENTS-FOR-ENTRY-VM-POINT...)
```
It will almost always look like:
```bash 
./somig -i Smalltalk:someDir -- NameOfEntryPointClass (maybe-other-arguments...)
```

- `RUNTIME-SETTINGS` include:

  - `-i` or `--import <DIR1:DIR2:DIR3:...>` - paths to directories (separated by `:`) which the runtime should look into when searching for `.som` class definitions (this option also has an alias `-cp` to be compatible with other SOM VMs).
  
  - `-r`, `-ri`, `-ir`, or `--recursively-include <DIR1:DIR2:DIR3:...>` same as `--import`, but allows the runtime to search the directories recursively.

  - `--no-color` - do not use ANSI for colored output of errors and warnings.

  - `--no-bs` (*no bootstrapping*) - makes it so that the entrypoint of the program is not the `initialize:` method of class `System` as it complicates the startup. The VM will do the work of this method by itself. This is useful for debugging as it simplifies the execution and makes the call-stack smaller.

  - `--object-stack <SIZE>` - sets the object-stack's size to `SIZE`. Defaults to `1000`.
  
  - `--frame-stack <SIZE>` - sets the frame-stack's size to `SIZE`. Defaults to `1000`.

The `ARGUMENTS-FOR-ENTRY-VM-POINT` are strings which will be passed into the runtime's entry point, which is by default the `initialize:` method on the class `System`. This method expects there to be at least one argument, which is the name of the class to run. Rest of the arguments are then passed into the `run:` method of the entry point class. The class can also only define the `run` method. See the `Smalltalk/System` class for more information.

It is also possible to specify the entry point class like this:
```bash
./somig -i Smalltalk path/to/NameOfEntryPointClass.som  (maybe-other-arguments...)
```
which de-sugars to:
```bash
./somig -i Smalltalk:path/to/ -- NameOfEntryPointClass  (maybe-other-arguments...)
```
This is implemented to be again compatible with other SOM VM implementations.
