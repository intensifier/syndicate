"use strict";
var Syndicate = require('../../src/main.js');
/// -->

/// This is an extended two-buyer book-purchase protocol, based
/// loosely on an example given in:
///
/// > K. Honda, N. Yoshida, and M. Carbone, “Multiparty asynchronous
/// > session types,” POPL 2008.

/// # The Scenario
///
/// A book-seller responds to requests for book prices when asked. A
/// pair of prospective buyers run through a shopping list. For each
/// book, the first buyer offers to split the cost of the book with
/// the second. If the second has enough money left, it accepts;
/// otherwise, it rejects the offer, and the first buyer tries a
/// different split. If the second buyer agrees to a split, it then
/// negotiates the purchase of the book with the book-seller.

/// # The Protocol

/// ## Role: SELLER
///
///  - when interest in `bookQuote($title, _)` appears,
///    asserts `bookQuote(title, Maybe Float)`, `false` meaning not available,
///    and otherwise an asking-price.
///  - when interest in `order($title, $offer-price, _, _)` appears,
///    asserts `order(title, offer-price, false, false)` for "no sale", otherwise
///    `order(title, offer-price, PositiveInteger, String)`, an accepted sale.

/// ## Role: BUYER
///
///  - observes `bookQuote(title, $price)` to learn prices.
///  - observes `order(title, offer-price, $id, $delivery-date)` to make orders.

/// ## Role: SPLIT-PROPOSER
///
///  - observes `splitProposal(title, asking-price, contribution, $accepted)`
///    to make a split-proposal and learn whether it was accepted or not.

/// ## Role: SPLIT-DISPOSER
///
///  - when interest in `splitProposal($title, $asking-price, $contribution, _)`
///    appears, asserts `splitProposal(title, askingPrice, contribution, true)`
///    to indicate they are willing to go through with the deal, in which case
///    they then perform the role of BUYER for title/asking-price, or asserts
///    `splitProposal(title, asking-price, contribution, false)` to indicate they
///    are unwilling to go through with the deal.

/// # A Sample Run
///
/// Run the program with `../../bin/syndicatec index.js | node` from a
/// checkout of the Syndicate repository.
///
///     A learns that the price of Catch 22 is 2.22
///     A makes an offer to split the price of Catch 22 contributing 1.11
///     B is being asked to contribute 1.11 toward Catch 22 at price 2.22
///     B accepts the offer, leaving them with 3.8899999999999997 remaining funds
///     A learns that the split-proposal for Catch 22 was accepted
///     A learns that Encyclopaedia Brittannica is out-of-stock.
///     The order for Catch 22 has id 10001483, and will be delivered on March 9th
///     A learns that the price of Candide is 34.95
///     A makes an offer to split the price of Candide contributing 17.475
///     B is being asked to contribute 17.475 toward Candide at price 34.95
///     B hasn't enough funds (3.8899999999999997 remaining)
///     A learns that the split-proposal for Candide was rejected
///     A makes an offer to split the price of Candide contributing 26.212500000000002
///     B is being asked to contribute 8.7375 toward Candide at price 34.95
///     B hasn't enough funds (3.8899999999999997 remaining)
///     A learns that the split-proposal for Candide was rejected
///     A makes an offer to split the price of Candide contributing 30.581250000000004
///     B is being asked to contribute 4.368749999999999 toward Candide at price 34.95
///     B hasn't enough funds (3.8899999999999997 remaining)
///     A learns that the split-proposal for Candide was rejected
///     A makes an offer to split the price of Candide contributing 32.765625
///     B is being asked to contribute 2.184375000000003 toward Candide at price 34.95
///     B accepts the offer, leaving them with 1.7056249999999968 remaining funds
///     A learns that the split-proposal for Candide was accepted
///     A learns that the price of The Wind in the Willows is 3.95
///     A makes an offer to split the price of The Wind in the Willows contributing 1.975
///     The order for Candide has id 10001484, and will be delivered on March 9th
///     B is being asked to contribute 1.975 toward The Wind in the Willows at price 3.95
///     B hasn't enough funds (1.7056249999999968 remaining)
///     A learns that the split-proposal for The Wind in the Willows was rejected
///     A makes an offer to split the price of The Wind in the Willows contributing 2.9625000000000004
///     B is being asked to contribute 0.9874999999999998 toward The Wind in the Willows at price 3.95
///     B accepts the offer, leaving them with 0.718124999999997 remaining funds
///     A learns that the split-proposal for The Wind in the Willows was accepted
///     A has bought everything they wanted!
///     The order for The Wind in the Willows has id 10001485, and will be delivered on March 9th

/// # The Code

/// ## Type Declarations

/// First, we declare *assertion types* for our protocol.

var bookQuote = Syndicate.Struct.makeConstructor("bookQuote", ["title","price"]);
var order = Syndicate.Struct.makeConstructor("order", ["title","price","id","deliveryDate"]);

var splitProposal = Syndicate.Struct.makeConstructor("splitProposal", ["title","price","contribution","accepted"]);

/// ## Utilities

/// This routine is under consideration for possible addition to the
/// core library.
///
function whileRelevantAssert(P) {
  (function () { 
Syndicate.Actor.createFacet()
.addAssertion((function() { var _ = Syndicate.__; return Syndicate.Patch.assert(P, 0); }))
.onEvent(true, "retracted", (function() { var _ = Syndicate.__; return Syndicate.Patch.sub(Syndicate.observe(P), 0); }), (function() { var _ = Syndicate.__; return { assertion: Syndicate.observe(P), metalevel: 0 }; }), (function() {})).completeBuild(); })();
}

/// ## Implementation: SELLER

function seller() {
  Syndicate.Actor.spawnActor(new Object(), function() {

/// We give our actor two state variables: a dictionary recording our
/// inventory of books (mapping title to price), and a counter
/// tracking the next order ID to be allocated.

    this.books = {
      "The Wind in the Willows": 3.95,
      "Catch 22": 2.22,
      "Candide": 34.95
    };
    this.nextOrderId = 10001483;

/// The seller responds to interest in bookQuotes by asserting a
/// responsive record, if one exists.

    (function () { 
Syndicate.Actor.createFacet()
.onEvent(false, "asserted", (function() { var _ = Syndicate.__; return Syndicate.Patch.sub(Syndicate.observe(bookQuote(_, _)), 0); }), (function() { var _ = Syndicate.__; return { assertion: Syndicate.observe(bookQuote((Syndicate._$("title")), _)), metalevel: 0 }; }), (function(title) { 
var _cachedAssertion1468253139911_0 = (function() { var _ = Syndicate.__; return Syndicate.observe(bookQuote(title, _)); })();
Syndicate.Actor.createFacet()
.addAssertion((function() { var _ = Syndicate.__; return Syndicate.Patch.assert(bookQuote(title, title in this.books ? this.books[title] : false), 0); }))
.onEvent(true, "retracted", (function() { var _ = Syndicate.__; return Syndicate.Patch.sub(_cachedAssertion1468253139911_0, 0); }), (function() { var _ = Syndicate.__; return { assertion: _cachedAssertion1468253139911_0, metalevel: 0 }; }), (function() {})).completeBuild(); })).completeBuild(); })();

/// It also responds to order requests.

    (function () { 
Syndicate.Actor.createFacet()
.onEvent(false, "asserted", (function() { var _ = Syndicate.__; return Syndicate.Patch.sub(Syndicate.observe(order(_, _, _, _)), 0); }), (function() { var _ = Syndicate.__; return { assertion: Syndicate.observe(order((Syndicate._$("title")), (Syndicate._$("offerPrice")), _, _)), metalevel: 0 }; }), (function(title, offerPrice) {

/// We cannot sell a book we do not have, and we will not sell for
/// less than our asking price.

        var askingPrice = title in this.books ? this.books[title] : false;
        if ((askingPrice === false) || (offerPrice < askingPrice)) {
          whileRelevantAssert(order(title, offerPrice, false, false));
        } else {

/// But if we can sell it, we do so by allocating an order ID and
/// replying to the orderer.

          var orderId = this.nextOrderId++;
          delete this.books[title];

          Syndicate.Actor.spawnActor(new Object(), function() {
            whileRelevantAssert(order(title, offerPrice, orderId, "March 9th"));
          });
        }
      })).completeBuild(); })();
  });
}

/// ## Implementation: SPLIT-PROPOSER and book-quote-requestor

function buyerA() {
  Syndicate.Actor.spawnActor(new Object(), function() {
    var self = this;

/// Our actor remembers which books remain on its shopping list, and
/// tries to buy them one at a time, sharing costs with `buyerB`.

    self.titles = ["Catch 22",
                   "Encyclopaedia Brittannica",
                   "Candide",
                   "The Wind in the Willows"];

/// JavaScript's callback-oriented blocking means that we express our
/// loop in almost a tail-recursive style, using helper functions
/// `buyBooks` and `trySplit`.

    buyBooks();

    function buyBooks() {
      if (self.titles.length === 0) {
        console.log("A has bought everything they wanted!");
        return;
      }

      var title = self.titles.shift();

/// First, retrieve a quote for the title, and analyze the result.

      (function () { 
Syndicate.Actor.createFacet()
.onEvent(true, "asserted", (function() { var _ = Syndicate.__; return Syndicate.Patch.sub(bookQuote(title, _), 0); }), (function() { var _ = Syndicate.__; return { assertion: bookQuote(title, (Syndicate._$("price"))), metalevel: 0 }; }), (function(price) {
          if (price === false) {
            console.log("A learns that "+title+" is out-of-stock.");
            buyBooks();
          } else {
            console.log("A learns that the price of "+title+" is "+price);

/// Next, repeatedly make split offers to a SPLIT-DISPOSER until
/// either one is accepted, or the contribution from the
/// SPLIT-DISPOSER becomes pointlessly small. We start the process by
/// offering to split the price of the book evenly.

            trySplit(title, price, price / 2);
          }
        })).completeBuild(); })();
    }

    function trySplit(title, price, contribution) {
      console.log("A makes an offer to split the price of "+title+
                  " contributing "+contribution);

/// If we are about to offer to split the price, but the other buyer
/// would contribute less than 10c, then it's not worth bothering; we
/// may as well buy it ourselves. Another version of the program could
/// perform the BUYER role here.

      if (contribution > (price - 0.10)) {
        console.log("A gives up on "+title+".");
        buyBooks();
      } else {

/// Make our proposal, and wait for a response.

        (function () { 
Syndicate.Actor.createFacet()
.onEvent(true, "asserted", (function() { var _ = Syndicate.__; return Syndicate.Patch.sub(splitProposal(title, price, contribution, true), 0); }), (function() { var _ = Syndicate.__; return { assertion: splitProposal(title, price, contribution, true), metalevel: 0 }; }), (function() {
            console.log("A learns that the split-proposal for "+title+" was accepted");
            buyBooks();
          }))
.onEvent(true, "asserted", (function() { var _ = Syndicate.__; return Syndicate.Patch.sub(splitProposal(title, price, contribution, false), 0); }), (function() { var _ = Syndicate.__; return { assertion: splitProposal(title, price, contribution, false), metalevel: 0 }; }), (function() {
            console.log("A learns that the split-proposal for "+title+" was rejected");
            trySplit(title, price, contribution + ((price - contribution) / 2));
          })).completeBuild(); })();
      }
    }
  });
}

/// ## Implementation: SPLIT-DISPOSER and BUYER

function buyerB() {
  Syndicate.Actor.spawnActor(new Object(), function() {

/// This actor maintains a record of the amount of money it has left
/// to spend.

    this.funds = 5.00;

/// It spends its time waiting for a SPLIT-PROPOSER to offer a
/// `splitProposal`.

    (function () { 
Syndicate.Actor.createFacet()
.onEvent(false, "asserted", (function() { var _ = Syndicate.__; return Syndicate.Patch.sub(Syndicate.observe(splitProposal(_, _, _, _)), 0); }), (function() { var _ = Syndicate.__; return { assertion: Syndicate.observe(splitProposal((Syndicate._$("title")), (Syndicate._$("price")), (Syndicate._$("theirContribution")), _)), metalevel: 0 }; }), (function(title, price, theirContribution) {
        var myContribution = price - theirContribution;
        console.log("B is being asked to contribute "+myContribution+" toward "+title+
                    " at price "+price);

/// We may not be able to afford contributing this much.

        if (myContribution > this.funds) {
          console.log("B hasn't enough funds ("+this.funds+" remaining)");
          whileRelevantAssert(splitProposal(title, price, theirContribution, false));
        } else {

/// But if we *can* afford it, update our remaining funds and spawn a
/// small actor to handle the actual purchase now that we have agreed
/// on a split.

          var remainingFunds = this.funds - myContribution;
          console.log("B accepts the offer, leaving them with "+remainingFunds+" remaining funds");
          this.funds = remainingFunds;

          Syndicate.Actor.spawnActor(new Object(), function() {
            (function () { 
Syndicate.Actor.createFacet()
.addAssertion((function() { var _ = Syndicate.__; return Syndicate.Patch.assert(splitProposal(title, price, theirContribution, true), 0); }))
.onEvent(true, "asserted", (function() { var _ = Syndicate.__; return Syndicate.Patch.sub(order(title, price, _, _), 0); }), (function() { var _ = Syndicate.__; return { assertion: order(title, price, (Syndicate._$("id")), (Syndicate._$("date"))), metalevel: 0 }; }), (function(id, date) {
                console.log("The order for "+title+" has id "+id+
                            ", and will be delivered on "+date);
              })).completeBuild(); })();
          });
        }
      })).completeBuild(); })();
  });
}

/// ## Starting Configuration

new Syndicate.Ground(function () {
  seller();
  buyerA();
  buyerB();
}).startStepping();
