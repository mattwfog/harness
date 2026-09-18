(lang dune 3.11)
(name harness)
(generate_opam_files true)

(package
 (name harness)
 (synopsis
  "Agent runtime: every agent action is an algebraic effect; the harness is the handler stack")
 (depends (ocaml (>= 5.1)) dune cmdliner yojson otoml (alcotest :with-test)))

(package
 (name harness-verdict)
 (synopsis "Deterministic verdict core: detectors, MECE matrix, Wilson report, shaping-lock gate")
 (depends (ocaml (>= 5.1)) dune cmdliner yojson re digestif (alcotest :with-test)))
