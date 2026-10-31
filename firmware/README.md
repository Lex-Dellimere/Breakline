# firmware

Nerves project wrapping `gateway/` for an x86_64 mini PC with 2 NICs. Not started; it is phase 6.

The stock `nerves_system_x86_64` only enables virtio networking and ships OTP 29, so real hardware
needs a custom system with the right NIC drivers. See `docs/DECISIONS.md` (D9).
