# json2zig

Generate zig types from json.

## Example:

### Input:

```json
{
    "people": [
        {
            "first_name": "Gordon",
            "last_name": "Freeman",
            "age": 27
        },
        {
            "first_name": "Bob",
            "email": "bob@example.com"
        }
    ]
}
```

### Output:
```zig
struct {
    people: []struct {
        first_name: []const u8,
        email: ?[]const u8,
        last_name: ?[]const u8,
        age: ?i64,
    },
}
```

## Building

Zig version 0.15.1.

```shell
zig build
```
