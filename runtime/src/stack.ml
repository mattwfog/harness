(* The handler stack, composed in its one canonical order:

     world (outermost — touches reality)
       ^ policy (person-in-command: checks, denies)
         ^ capture (journals everything, denials included)
           ^ the agent program

   Effects performed by the program hit capture first, then policy, then
   world; results flow back through the same layers. M2 adds the replay
   handler here (world swapped for a journal reader) and M3 the revert
   layer. *)

let run ~(world : Handler_world.config) ~(policy : Policy.t)
    ~(journal : Journal.t) (program : unit -> 'a) : 'a =
  Handler_world.run world (fun () ->
      Handler_policy.run policy (fun () ->
          Handler_capture.run journal program))
