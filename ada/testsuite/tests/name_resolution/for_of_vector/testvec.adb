with Ada.Containers.Vectors;
with Ada.Text_IO; use Ada.Text_IO;

procedure Testvec is
   package Int_Vecs is new Ada.Containers.Vectors (Natural, Integer);

   I : Int_Vecs.Vector;
   A : Integer;
begin
   I.Append (12);
   I.Append (12);
   I.Append (12);
   I.Append (12);

   for El of I loop
      A := El;
   end loop;

end Testvec;
pragma Test_Block;
