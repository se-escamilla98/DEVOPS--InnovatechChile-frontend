import { useState, useEffect } from "react";

function App() {
  const [productos, setProductos] = useState([]);
  const [nombre, setNombre] = useState("");
  const [precio, setPrecio] = useState("");
  const [status, setStatus] = useState("Verificando conexión...");

  const API_URL = import.meta.env.VITE_API_URL ?? "";

  // Al cargar la app, verificamos que el backend responde
  useEffect(() => {
    fetch(`${API_URL}/health`)
      .then((res) => res.json())
      .then((data) => setStatus(data.message))
      .catch(() => setStatus("Error: no se puede conectar al backend"));
  }, []);

  // Cargamos los productos desde la API
  useEffect(() => {
    fetch(`${API_URL}/api/productos`)
      .then((res) => res.json())
      .then((data) => setProductos(data))
      .catch((err) => console.error("Error cargando productos:", err));
  }, []);

  // Función para crear un producto nuevo
  const crearProducto = async () => {
    if (!nombre || !precio) return;
    const res = await fetch(`${API_URL}/api/productos`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ nombre, precio: parseFloat(precio) }),
    });
    const nuevo = await res.json();
    setProductos([...productos, nuevo]);
    setNombre("");
    setPrecio("");
  };

  return (
    <div style={{ fontFamily: "Arial", maxWidth: "600px", margin: "40px auto", padding: "0 20px" }}>
      <h1>Innovatech Chile</h1>
      <p>Estado del backend: <strong>{status}</strong></p>

      <h2>Productos</h2>

      <div style={{ marginBottom: "20px" }}>
        <input
          placeholder="Nombre del producto"
          value={nombre}
          onChange={(e) => setNombre(e.target.value)}
          style={{ marginRight: "10px", padding: "5px" }}
        />
        <input
          placeholder="Precio"
          value={precio}
          onChange={(e) => setPrecio(e.target.value)}
          style={{ marginRight: "10px", padding: "5px" }}
        />
        <button onClick={crearProducto} style={{ padding: "5px 10px" }}>
          Agregar
        </button>
      </div>

      {productos.length === 0 ? (
        <p>No hay productos aún.</p>
      ) : (
        <ul>
          {productos.map((p) => (
            <li key={p.id}>{p.nombre} — ${p.precio}</li>
          ))}
        </ul>
      )}
    </div>
  );
}

export default App;