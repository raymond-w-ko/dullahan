# Dullahan Wire Protocol

## Overview

Communication between server and client uses WebSocket with binary messages.

## Message Types

TODO: Define message types

### Server → Client

- `Snapshot` — full terminal state
- `Delta` — incremental update

### Client → Server

- `Input` — keyboard/mouse input
- `Resize` — terminal resize request
