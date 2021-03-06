Ideas on TCP unit testing:
<https://www.snellman.net/blog/archive/2015-07-09-unit-testing-a-tcp-stack/>

Check behaviour around TCP zero-window probing. Is the correct
behaviour already a consequence of the way `send-outbound` works?

Do something smarter with TCP timers and RTT estimation than the
nothing that's already being done.

TCP options negotiation.
 - SACK
 - Window scaling

Check that we handle the situations in figs. 9, 10, 11, pp.33- of RFC 793.

Bugs:
 - RST kills a connection even if its sequence number is bogus. Check
   to make sure it's in the window. (See
   http://static.googleusercontent.com/media/research.google.com/en//pubs/archive/41848.pdf
   and RFC 5961)

   Conform better to the rules for reset generation and processing
   from pp.36- of RFC 793. In particular, do not blindly accept RSTs
   without checking sequence numbers against windows etc.
