************
Introduction
************

Libadalang is a library for parsing and semantic analysis of Ada code. It is
meant as a building block for integration into other tools (IDE,
static-analyzers, etc..)

The aim of libadalang is to provide complete syntactic analysis with error
recovery, producing a precise Abstract Syntax Tree, and to provide name
resolution and precise cross-references on the resulting trees.

It is not (at the moment) to provide full legality checks for the Ada language.
If you want such a functionality, you'll need to use a full Ada compiler, such
as GNAT.

Need
####

The need for Libadalang arises from the conflation of different goals that we
have while designing Ada tooling at AdaCore. Here are those goals:

* We need to make tooling that is Ada aware, both at the syntactic and the
  semantic level

* We need to avoid repeating ourselves, that is to avoid duplicating the same
  code in dozens of places in our codebase, so we want to have a unified
  approach to this problem.

* We need in some cases (such as IDEs) to make tooling that can work with
  incorrect and/or evolving Ada code.

* We need a tool that can work incrementally, eg. doesn't have to start from
  scratch if you change a variable name in the dependency of a file you want to
  analyze.

Enter Libadalang
################

We are going to base our examples on this simple snippet of Ada code:

.. code-block:: ada
    :linenos:

    procedure Test (A : Foo; B : Bar) is
    begin
        for El : Foo_Elem of A loop
            if not El.Is_Empty then
                return B.RealBar (El);
            end if;
        end loop;
    end Test;

In the following examples, we will show how to accomplish the same thing with
Libadalang, with the Ada API, and with the Python API.

The Ada API is great for integration in existing Ada programs, and for
situations where you need some speed and static safety guaranties.

The Python API is great for rapid prototyping of programs using Libadalang. We
greatly encourage even Ada die-hard to try out the Python API for exploring the
API, and the tree structures and available accessors. They map directly to the
Ada API, so the knowledge is shared.

Parsing a file
**************

Let's say we did put the content of the above Ada snippet in the test.adb file.
Here is how you can parse the resulting file with Libadalang.

.. code-block:: ada

    with Ada.Text_IO;          use Ada.Text_IO;
    with Libadalang.Analysis;  use Libadalang.Analysis;

    procedure Main is
       Ctx       : Analysis_Context := Create;
       Unit      : Analysis_Unit := Get_From_File (Ctx, "test.adb");
    begin
       Print (Unit);
       Destroy (Ctx);
       Put_Line ("Done.");
    end Main;

This snippet will create an analysis context, which usually corresponds to the
context of your whole analysis - be it just one file, a whole project, or
several projects - and parse our Ada file and return the resulting AnalysisUnit
instance. Calling the ``Print`` function on the instance will dump the
resulting tree.

.. code::

    CompilationUnit[1:2-5:11]
    | body:
    | | LibraryItem[1:2-5:10]
    | | | is_private: False
    | | | item:
    | | | | SubprogramBody[1:2-5:10]
    | | | | | overriding: unspecified
    | | | | | subp_spec:
    | | | | | | SubprogramSpec[1:2-1:35]
    | | | | | | | name:
    | | | | | | | | Id[1:12-1:16]
    | | | | | | | | | tok: Test
    | | | | | | | params:
    ... continued

Exploring the tree
******************

The first thing you can do with this is explore the syntax tree through simple
accessors.


.. code-block:: ada

    with Ada.Text_IO;          use Ada.Text_IO;
    with Libadalang.Analysis;  use Libadalang.Analysis;
    with Libadalang.AST;       use Libadalang.AST;
    with Libadalang.AST.Types; use Libadalang.AST.Types;

    procedure Main is
       Ctx       : Analysis_Context := Create;
       Unit      : Analysis_Unit    := Get_From_File (Ctx, "test.adb");
       CU        : Compilation_Unit := Compilation_Unit (Root (Unit));
       Bod       : Library_Item     := Library_Item (F_Body (CU));
       Subp      : Subprogram_Body  := Subprogram_Body (F_Item (Bod));
    begin
       Subp.Print;
       Destroy (Ctx);
    end Main;

This code will access the ``SubprogramBody`` of the Test subprogram that
constitutes the main element of our file. But as you can see, even if it is
precise, this is not a very practical way of exploring the tree.
