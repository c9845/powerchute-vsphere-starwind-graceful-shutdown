# powerchute-consolidate-vms README Addendum

## Testing:
Testing is quite simple since there isn't anything extremely dangerous about this script. Yes, a StarWind storage VM is shut down, but if your vSAN and vSphere cluster are operating correctly this should not be an issue. Obviously, you should test duing non-production hours first.

You may need to adjust the delays in the config file to compensate for your environment. Typically you want the delays to be as short as possible while still allowing for tail-end latency.
