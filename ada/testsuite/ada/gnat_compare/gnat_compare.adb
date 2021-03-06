with Ada.Command_Line;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;           use Ada.Text_IO;

with GNAT.OS_Lib; use GNAT.OS_Lib;

with GNATCOLL.Projects; use GNATCOLL.Projects;
with GNATCOLL.VFS;      use GNATCOLL.VFS;

with Langkit_Support.Slocs;          use Langkit_Support.Slocs;
with Libadalang.Analysis;            use Libadalang.Analysis;
with Libadalang.Unit_Files.Projects; use Libadalang.Unit_Files.Projects;

with String_Utils; use String_Utils;
with Xrefs;        use Xrefs;
with Xrefs_Wrapper;

procedure GNAT_Compare is

   type Comparison_Type is
     (Ok,
      --  When the xref from GNAT is the same as the xref from LAL

      Different,
      --  When both refs are equal but the referenced entity is not

      Error,
      --  When LAL raises a Property_Error

      Missing,
      --  When a xref from GNAT is missing from LAL

      Additional
      --  When a xref from LAL is missing from GNAT
     );
   --  Kind for differences between xrefs in GNAT and xrefs in LAL

   Enabled : array (Comparison_Type) of Boolean := (others => True);
   --  For each kind of xrefs difference, determine whether we should report it

   Show_Nodes     : Boolean := False;
   --  In report, whether to show nodes that LAL uses to resolve references

   Ignore_Columns : Boolean := False;
   --  Whether to ignore differences in column numbers for referenced entities

   procedure Report
     (Files               : File_Table_Type;
      GNAT_Xref, LAL_Xref : Xref_Type;
      Comp                : Comparison_Type;
      LAL_Node            : Ada_Node'Class);
   --  Depending on the Enabled array, emit a diagnostic for the comparison
   --  between GNAT_Xref and LAL_Xref, whose kind is Comp.

   procedure Load_Project
     (Project_File  : String;
      Scenario_Vars : String_Vectors.Vector;
      Project       : out Project_Tree_Access;
      Env           : out Project_Environment_Access;
      UFP           : out Unit_Provider_Access);
   --  Load the project file called Project_File into Project, according to the
   --  given Scenario_Vars variables. Create UFP accordingly.

   procedure Run_GPRbuild
     (Project_File  : String;
      Scenario_Vars : String_Vectors.Vector);
   --  Run "gprbuild" on Project_File, passing to it the given Scenario_Vars
   --  varibles.

   procedure Load_All_Xrefs_From_LI
     (Project      : Project_Tree'Class;
      Files        : in out File_Table_Type;
      Xrefs        : out Unit_Xrefs_Vectors.Vector;
      Source_Files : String_Vectors.Vector);
   --  Go through all library files in Project and read the xref information
   --  they contain. Build the Xrefs database from it.
   --
   --  Register only xrefs for references that come from files in Source_Files.
   --  Use all references if Source_Files is empty.

   procedure Compare_Xrefs
     (Files : in out File_Table_Type;
      Root  : Ada_Node;
      Xrefs : Xref_Vectors.Vector);
   --  Go through all files referenced in the Xrefs database and use LAL to
   --  resolve all xrefs. Compare both, reporting the differences using the
   --  Report procedure above.

   ------------------
   -- Load_Project --
   ------------------

   procedure Load_Project
     (Project_File  : String;
      Scenario_Vars : String_Vectors.Vector;
      Project       : out Project_Tree_Access;
      Env           : out Project_Environment_Access;
      UFP           : out Unit_Provider_Access) is
   begin
      Project := new Project_Tree;
      Initialize (Env);

      --  Set scenario variables
      for Assoc of Scenario_Vars loop
         declare
            A        : constant String := +Assoc;
            Eq_Index : Natural := A'First;
         begin
            while Eq_Index <= A'Length and then A (Eq_Index) /= '=' loop
               Eq_Index := Eq_Index + 1;
            end loop;
            if Eq_Index not in A'Range then
               Put_Line ("Invalid scenario variable: -X" & A);
               raise Program_Error;
               return;
            end if;
            Change_Environment
              (Env.all,
               A (A'First .. Eq_Index - 1),
               A (Eq_Index + 1 .. A'Last));
         end;
      end loop;

      Load (Project.all, Create (+Project_File), Env);
      UFP := new Project_Unit_Provider_Type'(Create (Project, Env, False));
   end Load_Project;

   ------------------
   -- Run_GPRbuild --
   ------------------

   procedure Run_GPRbuild
     (Project_File  : String;
      Scenario_Vars : String_Vectors.Vector)
   is
      Path    : GNAT.OS_Lib.String_Access := Locate_Exec_On_Path ("gprbuild");
      Args    : String_Vectors.Vector;
      Success : Boolean;
   begin
      if Path = null then
         Put_Line ("Could not locate gprbuild on the PATH");
      end if;

      Args.Append (+"-q");
      Args.Append (+"-p");
      Args.Append (+"-P" & Project_File);
      for V of Scenario_Vars loop
         Args.Append ("-X" & V);
      end loop;

      declare
         Spawn_Args : String_List_Access :=
           new String_List'(To_String_List (Args));
      begin
         Spawn (Path.all, Spawn_Args.all, Success);
         Free (Spawn_Args);
         Free (Path);
      end;

      if not Success then
         Put_Line ("Could not spawn gprbuild");
         raise Program_Error;
      end if;
   end Run_GPRbuild;

   ----------------------------
   -- Load_All_Xrefs_From_LI --
   ----------------------------

   procedure Load_All_Xrefs_From_LI
     (Project      : Project_Tree'Class;
      Files        : in out File_Table_Type;
      Xrefs        : out Unit_Xrefs_Vectors.Vector;
      Source_Files : String_Vectors.Vector)
   is
      LIs : Library_Info_List;
   begin
      Project.Root_Project.Library_Files (List => LIs);
      for LI of LIs loop
         declare
            LI_Filename : constant String := +Full_Name (LI.Library_File);
            New_Xrefs   : Unit_Xrefs_Vectors.Vector;
         begin
            Read_LI_Xrefs (LI_Filename, Files, New_Xrefs);
            for NX of New_Xrefs loop
               if Source_Files.Is_Empty
                 or else Source_Files.Contains (+Filename (Files, NX.Unit))
               then
                  Xrefs.Append (NX);
               else
                  Free (NX);
               end if;
            end loop;
         end;
      end loop;
      LIs.Clear;
   end Load_All_Xrefs_From_LI;

   -------------------
   -- Compare_Xrefs --
   -------------------

   procedure Compare_Xrefs
     (Files : in out File_Table_Type;
      Root  : Ada_Node;
      Xrefs : Xref_Vectors.Vector)
   is

      Index  : constant File_Index_Type :=
        File_Index (Files, Get_Filename (Root.Get_Unit));

      Cursor : Natural := Xrefs.First_Index;
      --  Index of the next xref in Xrefs to use for comparison

      function Traverse (Node : Ada_Node'Class) return Visit_Status;
      --  Called for all AST nodes under Root

      function Resolve (Node : Ada_Node'Class) return Basic_Decl;
      --  Try to resolve Node into the corresponding declaration, applying
      --  post-processing from Xrefs_Wrapper. Retu

      procedure Process (LAL_Xref : Xref_Type; LAL_Node : Ada_Node'Class);
      --  Helper called from Traverse to run for all resolutions that either
      --  failed or succeeded and returned a non-null referenced declaration.

      --------------
      -- Traverse --
      --------------

      function Traverse (Node : Ada_Node'Class) return Visit_Status is
         Ref  : Basic_Decl;
         Xref : Xref_Type;
      begin
         --  GNAT only considers leaf items for xrefs, so skip for instance
         --  Dotted_Name nodes here.
         if Node.Kind not in Ada_String_Literal | Ada_Identifier then
            return Into;
         end if;

         --  Node is the "referencing" part of the xref...
         Xref.Ref_Sloc := Start_Sloc (Node.Sloc_Range);
         Xref.Ref_File := Index;
         Xref.Error := False;

         --  ... Ref will be the "referenced" part.
         begin
            Ref := Resolve (Node);
         exception
            when Property_Error =>
               Xref.Error := True;
         end;

         if Xref.Error then
            null;

         elsif not Ref.Is_Null then
            Xref.Entity_Sloc := Start_Sloc (Ref.Sloc_Range);
            Xref.Entity_File :=
              File_Index (Files, Get_Filename (Ref.Get_Unit));

         else
            --  When execution reached this place, we got no error and the
            --  referenced entity is "null", which means: this resolves to
            --  nothing. So consider there is no xref.
            return Into;
         end if;

         Process (Xref, Node);
         return Into;
      end Traverse;

      -------------
      -- Resolve --
      -------------

      function Resolve (Node : Ada_Node'Class) return Basic_Decl is
         Ref : Basic_Decl;
      begin
         for Wrapper of Xrefs_Wrapper.Pre_Wrappers loop
            declare
               Wrapped_Ref : constant Basic_Decl := Wrapper (Node);
            begin
               if not Wrapped_Ref.Is_Null then
                  return Wrapped_Ref;
               end if;
            end;
         end loop;

         Ref := Node.P_Referenced_Decl;

         if not Ref.Is_Null then
            for Wrapper of Xrefs_Wrapper.Post_Wrappers loop
               declare
                  Wrapped_Ref : constant Basic_Decl := Wrapper (Ref);
               begin
                  if not Wrapped_Ref.Is_Null then
                     return Wrapped_Ref;
                  end if;
               end;
            end loop;
         end if;

         return Ref;
      end Resolve;

      -------------
      -- Process --
      -------------

      procedure Process (LAL_Xref : Xref_Type; LAL_Node : Ada_Node'Class) is
      begin
         while Cursor <= Xrefs.Last_Index loop
            declare
               GNAT_Xref : constant Xref_Type := Xrefs (Cursor);
               Comp      : Comparison_Type;
            begin
               pragma Assert (LAL_Xref.Ref_File = GNAT_Xref.Ref_File);

               --  Go through all entries in Xrefs that appear in the source
               --  file before the "referencing" part in LAL_Xref...

               case Compare (GNAT_Xref.Ref_Sloc, LAL_Xref.Ref_Sloc) is
                  when After =>
                     --  Here, GNAT_Xref appears before LAL_Xref, so LAL failed
                     --  to resolve it.

                     Report (Files, GNAT_Xref, LAL_Xref, Missing, LAL_Node);
                     Cursor := Cursor + 1;

                  when Inside =>
                     --  GNAT_Xref and LAL_Xref have the same "referencing"
                     --  part: consider they are both resolving the same
                     --  reference. Check that they both reference to the
                     --  same declaration (ignoring column number if asked to).

                     if LAL_Xref.Error then
                        Comp := Error;

                     elsif GNAT_Xref.Entity_Sloc = LAL_Xref.Entity_Sloc
                       or else (Ignore_Columns
                                and then GNAT_Xref.Entity_Sloc.Line
                                = LAL_Xref.Entity_Sloc.Line)
                     then
                        Comp := Ok;

                     else
                        Comp := Different;
                     end if;

                     Report (Files, GNAT_Xref, LAL_Xref, Comp, LAL_Node);
                     Cursor := Cursor + 1;
                     exit;

                  when Before =>
                     exit;
               end case;
            end;
         end loop;
      end Process;

   begin
      Root.Traverse (Traverse'Access);

      --  Here, we tried to resolve all nodes under Root, so if we still have
      --  unprocessed xrefs from GNAT, report them as missing from LAL.

      while Cursor <= Xrefs.Last_Index loop
         Report (Files, Xrefs (Cursor), (others => <>), Missing, No_Ada_Node);
         Cursor := Cursor + 1;
      end loop;
   end Compare_Xrefs;

   ------------
   -- Report --
   ------------

   procedure Report
     (Files               : File_Table_Type;
      GNAT_Xref, LAL_Xref : Xref_Type;
      Comp                : Comparison_Type;
      LAL_Node            : Ada_Node'Class) is
   begin
      if not Enabled (Comp) then
         return;
      end if;

      case Comp is
         when Ok | Different | Error | Missing =>
            Put (Files, GNAT_Xref);
            if Comp = Different then
               Put (" (LAL: " & Filename (Files, LAL_Xref.Entity_File)
                    & ':' & Image (LAL_Xref.Entity_Sloc) & ')');
            elsif Comp = Missing then
               Put (" (LAL: missing)");
            elsif Comp = Error then
               Put (" (LAL: error)");
            else
               Put (" (LAL: ok)");
            end if;

         when Additional =>
            Put (Files, LAL_Xref);
            Put (" (GNAT: missing)");
      end case;

      if Show_Nodes and then not LAL_Node.Is_Null then
         Put (' ' & LAL_Node.Short_Image);
      end if;
      New_Line;
   end Report;

   Project_File  : Unbounded_String;
   Scenario_Vars : String_Vectors.Vector;

   Project : Project_Tree_Access;
   Env     : Project_Environment_Access;
   Files   : File_Table_Type;

   UFP : Unit_Provider_Access;
   Ctx : Analysis_Context;

   Source_Files : String_Vectors.Vector;
   LI_Xrefs     : Unit_Xrefs_Vectors.Vector;

begin

   --  Decode all command-line arguments

   for I in 1 .. Ada.Command_Line.Argument_Count loop
      declare
         Arg : constant String := Ada.Command_Line.Argument (I);
      begin
         if Starts_With (Arg, "-P") then
            Project_File := +Strip_Prefix (Arg, "-P");

         elsif Starts_With (Arg, "-X") then
            Scenario_Vars.Append (+Strip_Prefix (Arg, "-X"));

         elsif Starts_With (Arg, "-d") then
            for C of Strip_Prefix (Arg, "-d") loop
               declare
                  Comp : constant Comparison_Type :=
                    (case C is
                        when 'o' => Ok,
                        when 'd' => Different,
                        when 'e' => Error,
                        when 'm' => Missing,
                        when 'a' => Additional,
                        when others => raise Program_Error
                          with "Invalid character: " & C);
               begin
                  Enabled (Comp) := False;
               end;
            end loop;

         elsif Arg = "-n" then
            Show_Nodes := True;

         elsif Arg = "-c" then
            Ignore_Columns := True;

         elsif Arg (Arg'First) = '-' then
            Put_Line ("Invalid argument: " & Arg);
            raise Program_Error;

         else
            Source_Files.Append (+Arg);
         end if;
      end;
   end loop;

   --  Build the input project and import the resulting xrefs database

   Load_Project (+Project_File, Scenario_Vars, Project, Env, UFP);
   Run_GPRbuild (+Project_File, Scenario_Vars);
   Load_All_Xrefs_From_LI (Project.all, Files, LI_Xrefs, Source_Files);

   --  Browse this database and compare it to what LAL can resolve

   Ctx := Create (Unit_Provider => Unit_Provider_Access_Cst (UFP));

   Sort (Files, LI_Xrefs);
   for Unit_Xrefs of LI_Xrefs loop
      declare
         Name : constant String := Filename (Files, Unit_Xrefs.Unit);
         Unit : constant Analysis_Unit := Get_From_File (Ctx, Name);
      begin
         Put_Line ("== " & Name & " ==");
         Sort (Files, Unit_Xrefs.Xrefs);
         Compare_Xrefs (Files, Root (Unit), Unit_Xrefs.Xrefs);
         Free (Unit_Xrefs);
      end;
   end loop;

   Destroy (Ctx);
   Free (Project);
   Free (Env);
end GNAT_Compare;
