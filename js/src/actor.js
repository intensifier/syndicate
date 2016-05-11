'use strict';

var Immutable = require('immutable');
var Dataspace = require('./dataspace.js').Dataspace;
var Mux = require('./mux.js');
var Patch = require('./patch.js');
var Trie = require('./trie.js');
var Util = require('./util.js');

//---------------------------------------------------------------------------

function spawnActor(state, bootFn) {
  Dataspace.spawn(new Actor(state, bootFn));
}

function Actor(state, bootFn) {
  this.state = state;
  this.facets = Immutable.Set();
  this.mux = new Mux.Mux();

  this.boot = function() {
    var self = this;
    withCurrentFacet(null, function () {
      bootFn.call(self.state);
    });
    self.checkForTermination();
  };
}

Actor.prototype.handleEvent = function(e) {
  this.facets.forEach(function (f) {
    withCurrentFacet(f, function () { f.handleEvent(e); });
  });
  this.checkForTermination();
};

Actor.prototype.addFacet = function(facet) {
  this.facets = this.facets.add(facet);
};

Actor.prototype.removeFacet = function(facet) {
  this.facets = this.facets.remove(facet);
};

Actor.prototype.checkForTermination = function() {
  if (this.facets.isEmpty()) {
    Dataspace.exit();
  }
};

//---------------------------------------------------------------------------

function createFacet() {
  return new Facet(Dataspace.activeBehavior());
}

function Facet(actor) {
  this.actor = actor;
  this.endpoints = Immutable.Map();
  this.initBlocks = Immutable.List();
  this.doneBlocks = Immutable.List();
  this.children = Immutable.Set();
  this.parent = Facet.current;
}

Facet.current = null;

function withCurrentFacet(facet, f) {
  var previous = Facet.current;
  Facet.current = facet;
  var result;
  try {
    result = f();
  } catch (e) {
    Facet.current = previous;
    throw e;
  }
  Facet.current = previous;
  return result;
}

Facet.prototype.handleEvent = function(e) {
  var facet = this;
  facet.endpoints.forEach(function(endpoint) {
    endpoint.handlerFn.call(facet.actor.state, e);
  });
  facet.refresh();
};

Facet.prototype.addAssertion = function(assertionFn) {
  return this.addEndpoint(new Endpoint(assertionFn, function(e) {}));
};

Facet.prototype.onEvent = function(isTerminal, eventType, subscriptionFn, projectionFn, handlerFn) {
  var facet = this;
  switch (eventType) {

  case 'message':
    return this.addEndpoint(new Endpoint(subscriptionFn, function(e) {
      if (e.type === 'message') {
        var proj = projectionFn.call(facet.actor.state);
        var spec = Patch.prependAtMeta(proj.assertion, proj.metalevel);
        var match = Trie.matchPattern(e.message, spec);
        // console.log(match);
        if (match) {
          if (isTerminal) { facet.terminate(); }
          Util.kwApply(handlerFn, facet.actor.state, match);
        }
      }
    }));

  case 'asserted': /* fall through */
  case 'retracted':
    return this.addEndpoint(new Endpoint(subscriptionFn, function(e) {
      if (e.type === 'stateChange') {
        var proj = projectionFn.call(facet.actor.state);
        var spec = Patch.prependAtMeta(proj.assertion, proj.metalevel);
        var objects = Trie.projectObjects(eventType === 'asserted'
                                          ? e.patch.added
                                          : e.patch.removed,
                                          spec);
        if (objects && objects.size > 0) {
          // console.log(objects.toArray());
          if (isTerminal) { facet.terminate(); }
          objects.forEach(function (o) { Util.kwApply(handlerFn, facet.actor.state, o); });
        }
      }
    }));

  case 'risingEdge':
    var endpoint = new Endpoint(function() { return Patch.emptyPatch; },
                                function(e) {
                                  var newValue = subscriptionFn.call(facet.actor.state);
                                  if (newValue && !this.currentValue) {
                                    if (isTerminal) { facet.terminate(); }
                                    handlerFn.call(facet.actor.state);
                                  }
                                  this.currentValue = newValue;
                                });
    endpoint.currentValue = false;
    return this.addEndpoint(endpoint);

  default:
    throw new Error("Unsupported Facet eventType: " + eventType);
  }
};

Facet.prototype.addEndpoint = function(endpoint) {
  var patch = endpoint.subscriptionFn.call(this.actor.state);
  var r = this.actor.mux.addStream(patch);
  this.endpoints = this.endpoints.set(r.pid, endpoint);
  Dataspace.stateChange(r.deltaAggregate);
  return this; // for chaining
};

Facet.prototype.addInitBlock = function(thunk) {
  this.initBlocks = this.initBlocks.push(thunk);
  return this;
};

Facet.prototype.addDoneBlock = function(thunk) {
  this.doneBlocks = this.doneBlocks.push(thunk);
  return this;
};

Facet.prototype.refresh = function() {
  var facet = this;
  var aggregate = Patch.emptyPatch;
  this.endpoints.forEach(function(endpoint, eid) {
    var patch =
        Patch.retract(Syndicate.__).andThen(endpoint.subscriptionFn.call(facet.actor.state));
    var r = facet.actor.mux.updateStream(eid, patch);
    aggregate = aggregate.andThen(r.deltaAggregate);
  });
  Dataspace.stateChange(aggregate);
};

Facet.prototype.completeBuild = function() {
  var facet = this;
  this.actor.addFacet(this);
  if (this.parent) {
    this.parent.children = this.parent.children.add(this);
  }
  withCurrentFacet(facet, function () {
    facet.initBlocks.forEach(function(b) { b.call(facet.actor.state); });
  });
};

Facet.prototype.terminate = function() {
  var facet = this;
  var aggregate = Patch.emptyPatch;
  this.endpoints.forEach(function(endpoint, eid) {
    var r = facet.actor.mux.removeStream(eid);
    aggregate = aggregate.andThen(r.deltaAggregate);
  });
  Dataspace.stateChange(aggregate);
  this.endpoints = Immutable.Map();
  if (this.parent) {
    this.parent.children = this.parent.children.remove(this);
  }
  this.actor.removeFacet(this);
  withCurrentFacet(facet, function () {
    facet.doneBlocks.forEach(function(b) { b.call(facet.actor.state); });
  });
  this.children.forEach(function (child) {
    child.terminate();
  });
};

//---------------------------------------------------------------------------

function Endpoint(subscriptionFn, handlerFn) {
  this.subscriptionFn = subscriptionFn;
  this.handlerFn = handlerFn;
}

//---------------------------------------------------------------------------

module.exports.spawnActor = spawnActor;
module.exports.createFacet = createFacet;