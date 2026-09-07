const field = document.getElementById("say");
const button = document.getElementById("click-me");
const status = document.getElementById("click-status");
let clicks = 0;

const describe = () => {
  const said = field.value.trim();
  if (clicks === 0 && !said) {
    return "script ran at " + new Date().toLocaleTimeString();
  }
  const clickBit =
    clicks === 0 ? "not clicked yet"
    : clicks === 1 ? "clicked once"
    : "clicked " + clicks + " times";
  return said ? "“" + said + "” · " + clickBit : clickBit;
};

status.textContent = describe();
field.addEventListener("input", () => {
  status.textContent = describe();
});
button.addEventListener("click", () => {
  clicks += 1;
  status.textContent = describe();
  button.textContent = clicks < 8 ? "Again" : "Still going";
});
