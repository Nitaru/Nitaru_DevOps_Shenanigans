import { useEffect, useState } from "react";

export default function App() {
  const [notes, setNotes] = useState([]);
  const [source, setSource] = useState("");
  const [text, setText] = useState("");
  const [error, setError] = useState("");

  async function load() {
    try {
      const res = await fetch("/api/notes");
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      setNotes(data.notes);
      setSource(data.source);
      setError("");
    } catch (err) {
      setError(`Could not load notes: ${err.message}`);
    }
  }

  async function add(e) {
    e.preventDefault();
    if (!text.trim()) return;
    await fetch("/api/notes", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text }),
    });
    setText("");
    load();
  }

  async function remove(id) {
    await fetch(`/api/notes/${id}`, { method: "DELETE" });
    load();
  }

  useEffect(() => {
    load();
  }, []);

  return (
    <main>
      <h1>Notes</h1>
      <form onSubmit={add}>
        <input value={text} onChange={(e) => setText(e.target.value)} placeholder="Write a note..." />
        <button type="submit">Add</button>
      </form>

      {error && <p className="error">{error}</p>}
      {source && (
        <p className="source">
          Served from <span className={source}>{source}</span>
          <button className="link" onClick={load}>refresh</button>
        </p>
      )}

      <ul>
        {notes.map((n) => (
          <li key={n._id}>
            <span>{n.text}</span>
            <button className="link" onClick={() => remove(n._id)}>delete</button>
          </li>
        ))}
      </ul>
    </main>
  );
}
