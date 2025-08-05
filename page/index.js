
/** @type {WebAssembly.Instance|null} */
let instance = null;
(async () => {
    const instanceAndModule = await WebAssembly.instantiateStreaming(fetch('json2zig.wasm'));
    instance = instanceAndModule.instance;

    const ptr = instance.exports.alloc(32 * 1024);
    console.log(instance.exports.sizeOf(ptr));
    instance.exports.free(ptr);
})();

const editor = monaco.editor.create(document.getElementById('input'), {
    value: `{
    "key": "value"
}`,
    language: 'json',
    theme: 'vs-dark',
});
const output = document.getElementById('output');

editor.onDidChangeModelContent(() => {
    if (!instance) return;
    const json = editor.getValue();
    const encoder = new TextEncoder();
    const bytes = encoder.encode(json);
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

    output.innerText = str;
});

