export fn zig_array(x: [10]u8) void {
    try std.testing.expect(std.mem.eql(u8, &x, "1234567890"));
}
const std = @import("std");
export fn zig_return_array() [10]u8 {
    return "1234567890".*;
}

// error
// target=x86_64-linux
//
// :1:21: error: parameter of type '[10]u8' not allowed in function with calling convention 'x86_64_sysv'
// :1:21: note: arrays are not allowed as a parameter type
// :5:30: error: return type '[10]u8' not allowed in function with calling convention 'x86_64_sysv'
// :5:30: note: arrays are not allowed as a return type
