
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

const createString = (string) => {
    const encoder = new TextEncoder();
    const bytes = encoder.encode(string);
    const allocation = instance.exports.alloc(bytes.length);

    const wasm_bytes = new Uint8Array(instance.exports.memory.buffer, allocation, bytes.length);
    wasm_bytes.set(bytes);
    return allocation;
}

const update = () => {
    if (!instance) return;

    const options = createString(JSON.stringify({
        string:  document.querySelector('#option-string').value,
        integer: document.querySelector('#option-integer').value,
        float:   document.querySelector('#option-float').value,
        any:     document.querySelector('#option-any').value,
        unknown: document.querySelector('#option-unknown').value,
    }));

    const string = createString(input.getValue());
    const output_allocation = instance.exports.parse(string, options);
    instance.exports.free(string);
    instance.exports.free(options);

    if (output_allocation === 0) {
        output.setValue("Error!");
        return;
    }

    const output_bytes = new Uint8Array(instance.exports.memory.buffer, output_allocation, instance.exports.sizeOf(output_allocation));
    const decoder = new TextDecoder('utf-8');
    const str = decoder.decode(output_bytes);
    instance.exports.free(output_allocation);

    output.setValue(str);
}

input.onDidChangeModelContent(update);
for (const option of document.querySelectorAll('.option')) {
    option.addEventListener('input', update);
}

(async () => {
    const instanceAndModule = await WebAssembly.instantiateStreaming(fetch('json2zig.wasm'));
    instance = instanceAndModule.instance;
    update();
})();