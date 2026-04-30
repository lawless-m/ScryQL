:- use_module(library(format)).

:- dynamic(customer/1).
:- dynamic(invoice/3).
:- dynamic(uploaded/2).
:- dynamic(nonzerolines/1).

diag(Inv) :-
    format("~w:~n", [Inv]),
    ( invoice(Inv, C, D) -> format("  invoice    cust=~w date=~w~n", [C, D])
    ;                       format("  invoice    MISSING~n", []) ),
    ( uploaded(Inv, L)   -> format("  uploaded   loc=~w~n", [L])
    ;                       format("  uploaded   MISSING~n", []) ),
    ( nonzerolines(Inv)  -> format("  nonzero    yes~n", [])
    ;                       format("  nonzero    no~n", []) ).

classify(Inv, R) :-
    ( \+ invoice(Inv, _, _) -> R = fail(no_invoice, Inv)
    ; \+ uploaded(Inv, _)   -> R = fail(not_uploaded, Inv)
    ; \+ nonzerolines(Inv)  -> R = fail(empty_lines, Inv)
    ; R = ok ).
