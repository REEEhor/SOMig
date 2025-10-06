# **SOM**ig - a Zig implementation of SOM 

Simple Object Machine (SOM) is a minimal [Smalltalk](https://en.wikipedia.org/wiki/Smalltalk)-like language, used for the teaching and research of virtual machines.

This repository is an implementation of a virtual machine for SOM in the [Zig programming language](https://ziglang.org/).

SOMig is a bachelor's thesis. Click [here](https://gitlab.fit.cvut.cz/rehorja8/paper-part-of-somig) to go to the repository for the paper part of the thesis.

---
## Cloning the repo
The repository contains a Git submodule of the original SOM-st implementation.
The SOM-st repository contains code examples, which are (will be `:D`) used in tests.

So this repo has to be cloned with `--recurse-submodules`, if you also want to run the tests `:)`.
```bash
  git clone --recurse-submodules git@gitlab.fit.cvut.cz:rehorja8/somig.git
```