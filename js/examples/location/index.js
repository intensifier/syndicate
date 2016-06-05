assertion type location(id, email, timestamp, lat, lng);
message type findMarker(id);

var brokerConnection = Syndicate.Broker.brokerConnection;
var toBroker = Syndicate.Broker.toBroker;
var fromBroker = Syndicate.Broker.fromBroker;

ground dataspace G {
  Syndicate.UI.spawnUIDriver();
  Syndicate.Timer.spawnTimerDriver();
  Syndicate.Broker.spawnBrokerClientDriver();

  actor {
    var id = Syndicate.RandomID.randomId(4, true);

    var email_element = document.getElementById('my_email');
    if (localStorage.my_email) {
      email_element.value = localStorage.my_email;
    } else {
      localStorage.my_email = email_element.value = id;
    }

    var group_element = document.getElementById('group');
    var url_group_match = /group=(.*)$/.exec(document.location.search || '');
    if (url_group_match) {
      localStorage.group = group_element.value = url_group_match[1];
    } else if (localStorage.group) {
      group_element.value = localStorage.group;
    } else {
      localStorage.group = group_element.value = 'Public';
    }

    var mapInitialized = false;
    var map = new google.maps.Map(document.getElementById('map'), {
      center: {lat: 42, lng: -71},
      zoom: 18
    });

    var infoWindow = new google.maps.InfoWindow();
    var geocoder = new google.maps.Geocoder();

    var wsurl_base = 'wss://demo-broker.syndicate-lang.org:8443/location/';
    var wsurl = wsurl_base + group_element.value.trim();

    var watchId = ('geolocation' in navigator)
        && navigator.geolocation.watchPosition(Syndicate.Dataspace.wrap(function (pos) {
          :: location(id,
                      email_element.value.trim(),
                      +new Date(),
                      pos.coords.latitude,
                      pos.coords.longitude);
          if (!mapInitialized && map) {
            mapInitialized = true;
            map.setCenter({lat: pos.coords.latitude, lng: pos.coords.longitude});
          }
        }));

    react {
      var currentLocation = null;
      var selectedMarker = null;

      assert brokerConnection(wsurl);
      assert toBroker(wsurl, currentLocation) when (currentLocation);

      on message Syndicate.UI.globalEvent('#my_email', 'change', _) {
        localStorage.my_email = currentLocation[1] = email_element.value.trim();
      }

      on message Syndicate.UI.globalEvent('#group', 'change', _) {
        localStorage.group = group_element.value.trim();
        wsurl = wsurl_base + group_element.value.trim();
      }

      on message Syndicate.UI.globalEvent('#findMarker', 'click', $e) {
        :: findMarker(document.getElementById('markerList').value);
      }
      on message Syndicate.UI.globalEvent('#markerList', 'change', $e) {
        :: findMarker(document.getElementById('markerList').value);
      }

      on message ($loc = location(_, _, _, _, _)) {
        currentLocation = loc;
      }

      during fromBroker(wsurl, location($id, $email, _, _, _)) {
        var ui = new Syndicate.UI.Anchor();
        var marker = new google.maps.Marker({
          map: map,
          clickable: true,
          icon: 'https://www.gravatar.com/avatar/' + md5(email.trim().toLowerCase()) + '?s=32&d=retro'
        });
        var latestTimestamp = null;
        var latestPosition = null;
        function selectMarker() {
          selectedMarker = marker;
          updateInfoWindow();
          infoWindow.open(map, marker);
        }
        function updateInfoWindow() {
          if (selectedMarker === marker && latestPosition && latestTimestamp) {
            geocoder.geocode({'location': latestPosition}, function (results, status) {
              if (status === google.maps.GeocoderStatus.OK && results[0]) {
                infoWindow.setContent(Mustache.render(document.getElementById('info').innerHTML, {
                  email: email,
                  timestamp: latestTimestamp ? latestTimestamp.toString() : '',
                  address: results[0].formatted_address
                }));
              }
            });
          }
        }
        do {
          marker.addListener('click', Syndicate.Dataspace.wrap(function () {
            selectMarker();
          }));
        }
        assert ui.html('#markerList',
                       Mustache.render(document.getElementById('markerList-option').innerHTML, {
                         id: id,
                         email: email
                       }));
        on message findMarker(id) {
          selectMarker();
          if (latestPosition) map.panTo(latestPosition);
        }
        on asserted fromBroker(wsurl, location(id, email, $timestamp, $lat, $lng)) {
          latestTimestamp = new Date(timestamp);
          latestPosition = {lat: lat, lng: lng};
          marker.setPosition(latestPosition);
          marker.setTitle(email + ' ' + latestTimestamp.toTimeString());
          updateInfoWindow();
        }
        finally {
          marker.setMap(null);
          if (selectedMarker === marker) selectedMarker = null;
        }
      }
    }
  }
}
