import { h } from "preact";
import { useState, useEffect, useRef } from "preact/hooks";
import { TerminalConnection } from "../terminal/connection";
import type { TerminalSnapshot } from "../terminal/connection";

export function App() {
  const [connected, setConnected] = useState(false);
  const [snapshot, setSnapshot] = useState<TerminalSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const connectionRef = useRef<TerminalConnection | null>(null);

  useEffect(() => {
    const conn = new TerminalConnection();
    connectionRef.current = conn;

    conn.onConnect = () => {
      setConnected(true);
      setError(null);
    };

    conn.onDisconnect = () => {
      setConnected(false);
    };

    conn.onError = (err) => {
      setError(err);
    };

    conn.onSnapshot = (snap) => {
      setSnapshot(snap);
    };

    conn.connect();

    return () => {
      conn.disconnect();
    };
  }, []);

  return (
    <div style={{ 
      fontFamily: "monospace", 
      background: "#1a1a2e", 
      color: "#eee",
      minHeight: "100vh",
      padding: "1rem"
    }}>
      <header style={{ marginBottom: "1rem", borderBottom: "1px solid #333", paddingBottom: "0.5rem" }}>
        <h1 style={{ margin: 0, fontSize: "1.2rem" }}>
          Dullahan Terminal
          <span style={{ 
            marginLeft: "1rem", 
            fontSize: "0.8rem",
            color: connected ? "#4ade80" : "#f87171"
          }}>
            {connected ? "● Connected" : "○ Disconnected"}
          </span>
        </h1>
        {error && (
          <div style={{ color: "#f87171", marginTop: "0.5rem" }}>
            Error: {error}
          </div>
        )}
      </header>

      <main>
        {snapshot ? (
          <TerminalView snapshot={snapshot} />
        ) : (
          <div style={{ color: "#888" }}>
            {connected ? "Waiting for snapshot..." : "Connecting to server..."}
          </div>
        )}
      </main>
    </div>
  );
}

interface TerminalViewProps {
  snapshot: TerminalSnapshot;
}

function TerminalView({ snapshot }: TerminalViewProps) {
  const { cols, rows, cursor, content, altScreen } = snapshot;

  // Split content into lines
  const lines = content.split("\n");

  return (
    <div>
      <div style={{ 
        marginBottom: "0.5rem", 
        fontSize: "0.75rem", 
        color: "#888" 
      }}>
        {cols}x{rows} | Cursor: ({cursor.x}, {cursor.y}) {cursor.visible ? "visible" : "hidden"} | 
        {altScreen ? " Alt Screen" : " Primary Screen"}
      </div>

      <pre style={{
        background: "#0d0d1a",
        padding: "0.5rem",
        borderRadius: "4px",
        overflow: "auto",
        margin: 0,
        fontSize: "14px",
        lineHeight: "1.2",
        minHeight: `${rows * 1.2}em`,
      }}>
        {lines.map((line, y) => (
          <div key={y} style={{ height: "1.2em" }}>
            {renderLine(line, y, cursor)}
          </div>
        ))}
      </pre>
    </div>
  );
}

function renderLine(
  line: string, 
  y: number, 
  cursor: TerminalSnapshot["cursor"]
): preact.JSX.Element {
  // If cursor is on this line and visible, highlight the cursor position
  if (cursor.visible && cursor.y === y) {
    const before = line.slice(0, cursor.x);
    const cursorChar = line[cursor.x] || " ";
    const after = line.slice(cursor.x + 1);

    return (
      <>
        {before}
        <span style={{ 
          background: "#fff", 
          color: "#000"
        }}>
          {cursorChar}
        </span>
        {after}
      </>
    );
  }

  return <>{line || " "}</>;
}
