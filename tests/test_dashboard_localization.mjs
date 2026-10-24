// Runs the production renderer functions in isolation; no browser, server or device access.
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import vm from 'node:vm';

const nativeSource = new URL('../../Sources/NodivraDashboard/Resources/renderer.js', import.meta.url);
const sourceURL = existsSync(nativeSource) ? nativeSource : new URL('../nodivra_runtime/server/dashboard_web/renderer.js', import.meta.url);
const source = readFileSync(sourceURL, 'utf8');
const hook = '  window.Nodivra=';
assert.equal(source.split(hook).length, 2, 'Renderer exposes one bridge');
const context = vm.createContext({
  window: { addEventListener() {} },
  document: { getElementById() { return {}; }, addEventListener() {} },
  matchMedia() { return { matches: true }; },
  IntersectionObserver: class { observe() {} disconnect() {} },
  ResizeObserver: class { observe() {} },
  Intl
});
// Test-only exports avoid adding inspection APIs to the renderer shipped to users.
vm.runInContext(source.replace(hook, `
  globalThis.localeTest={tr,uiLanguage,uiLocale,displayState,weather,uiTranslations,
    setLocale(locale){payload=locale===undefined?{}:{uiLocale:locale};options={mode:'editor'};}};
${hook}`), context);
const api = context.localeTest;
const expected = [
  ['de', 'Regen', 'Offen', 'Geschlossen', '12,5 °C'],
  ['en', 'Rain', 'Open', 'Closed', '12.5 °C'],
  ['es', 'Lluvia', 'Abierto', 'Cerrado', '12,5 °C'],
  ['fr', 'Pluie', 'Ouvert', 'Fermé', '12,5 °C'],
  ['it', 'Pioggia', 'Aperto', 'Chiuso', '12,5 °C'],
  ['pt-BR', 'Chuva', 'Aberto', 'Fechado', '12,5 °C']
];
const keys = Object.keys(api.uiTranslations.en).sort();
const tokens = text => (text.match(/\{\w+\}/g) || []).sort();
for (const [locale, rain, open, closed, temperature] of expected) {
  api.setLocale(locale);
  assert.equal(api.uiLanguage(), locale);
  if (locale !== 'de') {
    assert.deepEqual(Object.keys(api.uiTranslations[locale]).sort(), keys);
    for (const key of keys) {
      assert.ok(api.uiTranslations[locale][key].length);
      assert.deepEqual(tokens(api.uiTranslations[locale][key]), tokens(key));
    }
  }
  const door = { binding: { entityID: 'binary_sensor.front_door' } };
  assert.equal(api.displayState(door, { value: 'on', deviceClass: 'door' }), open);
  assert.equal(api.displayState(door, { value: 'off', deviceClass: 'door' }), closed);
  assert.equal(api.displayState(door, { value: 'custom_user_state' }), 'custom_user_state');
  assert.equal(api.displayState(door, { value: '__proto__' }), '__proto__');
  assert.equal(api.tr('Benutzerdefinierter Hinweis'), 'Benutzerdefinierter Hinweis');
  assert.equal(api.tr('constructor'), 'constructor');
  const condition = {}, details = {}, node = {
    c: { cardStyle: 'detail', weather: {} }, value: {},
    card: { querySelector(selector) { return selector === '.weather-condition' ? condition : details; } }
  };
  const value = { known: true, value: 'rainy', temperature: 12.5, temperature_unit: '°C', humidity: 0, wind_speed: 8, wind_speed_unit: 'km/h' };
  api.weather(node, value);
  assert.equal(condition.textContent, rain);
  assert.equal(node.value.textContent, temperature);
  assert.equal(value.value, 'rainy', 'Integration identifiers are never translated');
  assert.ok(details.textContent.includes('0 %'), 'Zero humidity must not be treated as missing');
  api.weather(node, { known: true, value: 'future_weather_code' });
  assert.equal(condition.textContent, 'future_weather_code');
  api.weather(node, { known: true, value: '__proto__' });
  assert.equal(condition.textContent, '__proto__');
}
api.setLocale(undefined);
assert.equal(api.uiLanguage(), 'de', 'Published dashboards keep their existing default');
assert.equal(api.tr('Wert nicht verfügbar'), 'Wert nicht verfügbar');
api.setLocale('pt-PT');
assert.equal(api.uiLanguage(), 'pt-BR');
api.setLocale('es-ES');
assert.equal(api.tr('Regen'), 'Lluvia');
api.setLocale('en');
assert.equal(api.tr('{count} Messpunkte · {seconds} s · Min {min} / Max {max}', { count: 3, seconds: 2, min: 1.5, max: 3 }), '3 samples · 2 s · Min 1.5 / Max 3');
assert.equal(api.displayState({ binding: { entityID: 'binary_sensor.front_door' } }, { value: 'on', deviceClass: 'constructor' }), 'On');
api.setLocale('unknown');
assert.equal(api.uiLanguage(), 'de');
const serviceCopies = existsSync(nativeSource)
  ? ['../server/dashboard_web/renderer.js', '../../Dashboards/server/dashboard_web/renderer.js']
  : ['../nodivra_runtime/server/dashboard_web/renderer.js', '../nodivra_dashboards/server/dashboard_web/renderer.js'];
for (const path of serviceCopies) {
  assert.equal(readFileSync(new URL(path, import.meta.url), 'utf8'), source, 'Packaged renderer matches the shared source');
}
console.log(`Dashboard localization: ${keys.length} messages, six languages, state/weather/format/default checks passed.`);
