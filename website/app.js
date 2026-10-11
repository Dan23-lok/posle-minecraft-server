const copyButton = document.getElementById('copy-address');
const address = document.getElementById('server-address');
const status = document.getElementById('copy-status');

copyButton.addEventListener('click', async () => {
  const value = address.textContent.trim();
  try {
    await navigator.clipboard.writeText(value);
    status.textContent = 'Адрес скопирован. Вставь его в Minecraft → Сетевая игра.';
  } catch (_) {
    const selection = window.getSelection();
    const range = document.createRange();
    range.selectNodeContents(address);
    selection.removeAllRanges();
    selection.addRange(range);
    status.textContent = 'Адрес выделен. Нажми Ctrl+C, чтобы скопировать.';
  }
});
