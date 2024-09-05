# zig-asyncio

A high-level Zig library for dead simple asynchronous I/O.

This library is a rather minimal wrapper around [libxev](https://github.com/mitchellh/libxev) and [zigcoro](https://github.com/rsepassi/zigcoro) to provide an API that's a bit easier to use. Please support the creators of both projects, as this one would not be possible without their invaluable work! Also, don't flood their issue page with bugs until it's confirmed that it's an issue on _their_ end. Always make an issue here first.

Please note that when (and if) built-in async support for Zig returns, this project will not be ready. It was written with the pessimistic assumption that it would be too difficult to bring back and will be dropped.
