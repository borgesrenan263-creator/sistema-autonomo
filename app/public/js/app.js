function copyTask(id) {
  const el = document.getElementById(`copy-${id}`);

  if (!el) {
    alert("Conteúdo não encontrado.");
    return;
  }

  navigator.clipboard.writeText(el.value)
    .then(() => alert("Entrega copiada."))
    .catch(() => alert("Não foi possível copiar."));
}

console.log("SISTEMA_AUTONOMO_BOOT_OK");
