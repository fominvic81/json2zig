
/** @type {WebAssembly.Instance|null} */
let instance = null;

const input = monaco.editor.create(document.getElementById('input'), {
    value: `{\n    "integer": 1\n}`,
    language: 'json',
    theme: 'vs-dark',
});
const output = monaco.editor.create(document.getElementById('output'), {
    language: 'go', // TODO
    theme: 'vs-dark',
    readOnly: true,
});

const update = () => {
    if (!instance) return;
    const encoder = new TextEncoder();
    const bytes = encoder.encode(input.getValue());
    const allocation = instance.exports.alloc(bytes.length);

    const wasm_bytes = new Uint8Array(instance.exports.memory.buffer, allocation, bytes.length);
    wasm_bytes.set(bytes);
    const output_allocation = instance.exports.parse(allocation);
    instance.exports.free(allocation);

    if (output_allocation === 0) return;

    const output_bytes = new Uint8Array(instance.exports.memory.buffer, output_allocation, instance.exports.sizeOf(output_allocation));
    const decoder = new TextDecoder('utf-8');
    const str = decoder.decode(output_bytes);
    instance.exports.free(output_allocation);

    output.setValue(str);
}

input.onDidChangeModelContent(update);
(async () => {
    const instanceAndModule = await WebAssembly.instantiateStreaming(fetch('json2zig.wasm'));
    instance = instanceAndModule.instance;
    update();
})();