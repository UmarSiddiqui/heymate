// Just enough of React's API for blobatar's adapter to build live SVG nodes
// without React: useMemo runs once per call, and jsx() makes real elements.
var SVG = "http://www.w3.org/2000/svg";

export function useMemo(make) { return make(); }

export function jsx(type, props) {
  var el = document.createElementNS(SVG, type);
  for (var key in props) {
    var value = props[key];
    if (value == null || value === false) continue;
    if (key === "children") {
      [].concat(value).forEach(function (child) {
        if (child == null || child === false) return;
        el.appendChild(typeof child === "object" ? child : document.createTextNode(String(child)));
      });
    } else if (key === "dangerouslySetInnerHTML") {
      el.innerHTML = value.__html;
    } else if (key === "style") {
      for (var name in value) el.style.setProperty(name, value[name]);
    } else {
      el.setAttribute(key === "className" ? "class" : key, value === true ? "true" : String(value));
    }
  }
  return el;
}

export var jsxs = jsx;
