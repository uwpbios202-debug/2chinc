const baselineMonthly = 2654;
const goals = document.getElementById('goals');
const fields = [...goals.querySelectorAll('input')];
const example = document.getElementById('life');
const status = document.getElementById('goal-status');
const dollars = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' });

function update() {
  const validFields = fields.filter(field => field.value !== '' && field.validity.valid);
  const goalCents = validFields.reduce((sum, field) => sum + Math.round(field.valueAsNumber * 100), 0);
  const annual = (baselineMonthly + goalCents / 100) * 12;
  const missing = fields.length - validFields.length;
  const suffix = missing ? ' so far' : '';
  for (const [key, amount] of Object.entries({
    full: annual / 365, pay: annual / 365, month: annual / 12, year: annual, goals: goalCents / 100,
  })) {
    example.querySelector(`[data-${key}]`).textContent = dollars.format(amount) + suffix;
  }
  status.textContent = missing ? 'Some goal amounts are blank or invalid. The figures shown are subtotals.' : '';
}

goals.disabled = false;
goals.addEventListener('input', update);
document.getElementById('reset').addEventListener('click', () => {
  for (const field of fields) field.value = field.defaultValue;
  update();
});
update();
