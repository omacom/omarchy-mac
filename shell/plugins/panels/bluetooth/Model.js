function deviceLabel(device) {
  if (!device) return ""
  return String(device.deviceName || device.name || "").trim()
}

function toArray(values) {
  if (!values) return []
  if (Array.isArray(values)) return values.slice()

  var length = Number(values.length || 0)
  if (!isFinite(length) || length <= 0) return []

  var list = []
  for (var i = 0; i < length; i++) list.push(values[i])
  return list
}

function isUuidLike(value) {
  var text = String(value || "").trim()
  if (text === "") return false
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(text)
    || /^[0-9a-f]{32}$/i.test(text)
    || /^0x[0-9a-f]{4,32}$/i.test(text)
    || /^0000[0-9a-f]{4}-0000-1000-8000-00805f9b34fb$/i.test(text)
}

function isAddressLike(value) {
  var text = String(value || "").trim()
  return /^([0-9a-f]{2}[:-]){5}[0-9a-f]{2}$/i.test(text)
}

function normalizedAddress(value) {
  return String(value || "").trim().toLowerCase().replace(/[^0-9a-f]/g, "")
}

function hasHumanName(device) {
  var label = deviceLabel(device)
  return label !== "" && !isUuidLike(label) && !isAddressLike(label)
}

function nodeProps(node) {
  return node && node.ready && node.properties ? node.properties : {}
}

function nodeText(node) {
  var props = nodeProps(node)
  return [
    node ? node.name : "",
    node ? node.description : "",
    node ? node.nickname : "",
    node ? node.nick : "",
    props["node.name"],
    props["node.description"],
    props["node.nick"],
    props["device.name"],
    props["device.description"],
    props["device.product.name"],
    props["device.alias"],
    props["device.string"],
    props["api.bluez5.address"],
    props["bluez5.address"],
    props["media.name"]
  ].join(" ").toLowerCase()
}

function bluetoothSinkMatchesDevice(node, device) {
  if (!node || !node.isSink || node.isStream || !device) return false

  var address = normalizedAddress(device.address)
  var text = nodeText(node)
  if (address !== "" && normalizedAddress(text).indexOf(address) !== -1) return true

  var label = deviceLabel(device).toLowerCase()
  return label !== "" && text.indexOf(label) !== -1
}

function sortedByLabel(devices) {
  var list = toArray(devices)
  list.sort(function(a, b) { return deviceLabel(a).localeCompare(deviceLabel(b)) })
  return list
}

// Primitives-only projection of a BlueZ device for list-model rows. Holding
// the Device QObject in model data puts a live wrapper into every delegate's
// var property, and BlueZ churn (discovery timeouts, unpair) can destroy the
// object while a delegate is still incubating, which segfaults quickshell.
// Actions resolve the backend object via Panel.deviceFor().
function deviceRow(d) {
  if (!d) return null
  return {
    address: d.address || "",
    name: d.name || "",
    deviceName: d.deviceName || "",
    connected: !!d.connected,
    state: d.state !== undefined ? d.state : -1,
    batteryAvailable: !!d.batteryAvailable,
    battery: d.battery !== undefined ? d.battery : 0,
    pairing: !!d.pairing
  }
}

function deviceLists(devices) {
  var values = toArray(devices)
  var connected = []
  var known = []
  var discovered = []

  for (var i = 0; i < values.length; i++) {
    var d = values[i]
    if (!d || !hasHumanName(d)) continue
    if (d.connected) connected.push(d)
    else if (d.paired || d.bonded || d.trusted) known.push(d)
    else discovered.push(d)
  }

  return {
    connected: sortedByLabel(connected),
    known: sortedByLabel(known),
    discovered: sortedByLabel(discovered)
  }
}

function cloneMap(map) {
  var next = ({})
  for (var key in map || {}) next[key] = map[key]
  return next
}

function pendingAction(actions, address) {
  return address && actions && actions[address] ? actions[address] : ""
}

function withPendingAction(actions, address, action) {
  var next = cloneMap(actions)
  if (!address) return next
  if (action) next[address] = action
  else delete next[address]
  return next
}

// Classic HID devices (Apple keyboards, most mice) do not expose the GATT
// Battery Service BlueZ reads battery from. The kernel HID driver publishes
// their charge instead, as a sysfs power_supply node whose name embeds the
// device's Bluetooth MAC:
//   /sys/class/power_supply/hid-aa:bb:cc:dd:ee:ff-battery-<id>/capacity
// The node appears only once the HID link is up, so the panel cats it through
// a shell to let the id glob resolve.
function hidBatteryGlob(address) {
  var text = String(address || "").trim().toLowerCase()
  return isAddressLike(text)
    ? "/sys/class/power_supply/hid-" + text + "-battery-*/capacity"
    : ""
}

function hidBatteryCapacity(raw) {
  var value = parseInt(String(raw || "").trim(), 10)
  return isFinite(value) && value >= 0 && value <= 100 ? value : -1
}

// Apple earbuds push battery over the proprietary AAP L2CAP channel, which no
// BlueZ D-Bus surface exposes and no kernel power_supply node mirrors. Those
// devices go through the plugin-local airpods-battery.py one-shot probe
// instead: stdout JSON mirrors into a compact levels display, or "" when the
// probe found nothing. Name-based, because AAP answers only AirPods-family devices.
function looksLikeAirPods(name) {
  return /airpods/i.test(String(name || "").trim())
}

function airpodsLevels(raw) {
  var value
  try {
    value = JSON.parse(String(raw || ""))
  } catch (e) {
    return null
  }
  if (!value || typeof value !== "object" || value.error) return null

  var levels = {}
  var any = false
  var parts = ["left", "right", "case"]
  for (var i = 0; i < parts.length; i++) {
    var level = value[parts[i]]
    var valid = typeof level === "number" && isFinite(level) && level >= 0 && level <= 100
    levels[parts[i]] = valid ? Math.round(level) : null
    any = any || valid
  }
  return any ? levels : null
}

function airpodsText(levels) {
  if (!levels) return ""
  var text = []
  var order = ["left", "right", "case"]
  for (var i = 0; i < order.length; i++) {
    if (typeof levels[order[i]] === "number") text.push(levels[order[i]])
  }
  return text.length > 0 ? text.join("/") : ""
}

function visibleSections(lists, discovering) {
  var sections = []
  if (lists && lists.connected && lists.connected.length > 0) sections.push("connected")
  if (lists && lists.known && lists.known.length > 0) sections.push("known")
  if (discovering && lists && lists.discovered && lists.discovered.length > 0) sections.push("discovered")
  return sections
}

function sectionDevices(lists, section) {
  if (!lists) return []
  if (section === "connected") return lists.connected || []
  if (section === "known") return lists.known || []
  if (section === "discovered") return lists.discovered || []
  return []
}

if (typeof module !== "undefined") {
  module.exports = {
    deviceLabel: deviceLabel,
    toArray: toArray,
    isUuidLike: isUuidLike,
    isAddressLike: isAddressLike,
    normalizedAddress: normalizedAddress,
    hasHumanName: hasHumanName,
    nodeProps: nodeProps,
    nodeText: nodeText,
    bluetoothSinkMatchesDevice: bluetoothSinkMatchesDevice,
    sortedByLabel: sortedByLabel,
    deviceRow: deviceRow,
    deviceLists: deviceLists,
    cloneMap: cloneMap,
    pendingAction: pendingAction,
    withPendingAction: withPendingAction,
    visibleSections: visibleSections,
    sectionDevices: sectionDevices,
    hidBatteryGlob: hidBatteryGlob,
    hidBatteryCapacity: hidBatteryCapacity,
    looksLikeAirPods: looksLikeAirPods,
    airpodsLevels: airpodsLevels,
    airpodsText: airpodsText
  }
}
