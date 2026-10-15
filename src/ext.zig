const directory = @import("directory.zig");

pub const name = "ext2/ext3/ext4";
pub const native = false;
pub const search = directory.search;

// ext's HTree indexes individual directories; its ioctl API has no filename tree search.
pub fn supports(magic: usize) bool {
    return magic == 0xef53;
}
