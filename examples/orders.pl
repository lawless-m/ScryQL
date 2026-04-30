:- use_module(library(format)).
:- use_module(library(iso_ext)).  % for forall/2

% Facts populated by examples/orders.sql:
:- dynamic(order/4).      % order(Id, CustomerId, Total, Date)
:- dynamic(customer/3).   % customer(Id, Name, ActiveFlag)   ActiveFlag = active | inactive
:- dynamic(line/3).       % line(Product, Qty, Stock)
:- dynamic(payment/2).    % payment(Captured, Status)
:- dynamic(shipment/2).   % shipment(TrackingNo, Status)

% diag(+Order) -- side-effect mode.
% Walks every stage of the order's lifecycle, printing one line per stage
% and tagging the failed stages explicitly.
diag(Order) :-
    format("~w:~n", [Order]),
    show_order(Order),
    show_customer,
    show_lines,
    show_payment,
    show_shipment.

show_order(Order) :-
    ( order(Order, Cust, Total, Date)
    -> format("  order      cust=~w total=~w placed=~w~n", [Cust, Total, Date])
    ;  format("  order      MISSING~n", []) ).

show_customer :-
    ( customer(_, Name, active)
    -> format("  customer   ~w (active)~n", [Name])
    ;  customer(_, Name, inactive)
    -> format("  customer   ~w (INACTIVE)~n", [Name])
    ;  format("  customer   MISSING~n", []) ).

show_lines :-
    ( line(_, _, _)
    -> forall(line(P, Q, S),
              ( S >= Q
              -> format("  line       ~w qty=~w (stock=~w ok)~n", [P, Q, S])
              ;  format("  line       ~w qty=~w (stock=~w SHORT)~n", [P, Q, S]) ))
    ;  format("  line       NO LINES~n", []) ).

show_payment :-
    ( payment(C, S), order(_, _, T, _), C >= T
    -> format("  payment    ~w (~w)~n", [C, S])
    ;  payment(C, S), order(_, _, T, _)
    -> format("  payment    ~w of ~w (SHORT, ~w)~n", [C, T, S])
    ;  format("  payment    MISSING~n", []) ).

show_shipment :-
    ( shipment(Track, shipped)
    -> format("  shipment   ~w (shipped)~n", [Track])
    ;  shipment(Track, Status)
    -> format("  shipment   ~w (~w, NOT SHIPPED)~n", [Track, Status])
    ;  format("  shipment   NONE~n", []) ).

% classify(+Order, -Result) -- capture-result mode.
% Returns the first failure in priority order, or ok.
classify(Order, R) :-
    ( \+ order(Order, _, _, _)
    -> R = fail(no_order, Order)
    ;  customer(_, _, inactive)
    -> R = fail(inactive_customer, Order)
    ;  line_short(P, Q, S)
    -> R = fail(insufficient_stock, P, Q, S)
    ;  underpaid(C, T)
    -> R = fail(underpaid, C, T)
    ;  \+ shipment(_, shipped)
    -> R = fail(not_shipped, Order)
    ;  R = ok ).

line_short(P, Q, S) :-
    line(P, Q, S),
    S < Q.

underpaid(Captured, Total) :-
    payment(Captured, _),
    order(_, _, Total, _),
    Captured < Total.
