/* Test-only probe of libzfs's OBJ_TO_PATH wrapper; not linked into fslocate. */
#include <libzfs.h>
#include <stdio.h>
#include <sys/stat.h>

int main(int argc, char **argv)
{
    if (argc != 4) {
        fprintf(stderr, "usage: zfs_native_api POOL DATASET HARDLINK\n");
        return 2;
    }
    struct stat st;
    if (stat(argv[3], &st) != 0 || st.st_nlink < 2) {
        fprintf(stderr, "probe requires an existing file with multiple hardlinks\n");
        return 2;
    }
    libzfs_handle_t *hdl = libzfs_init();
    if (!hdl) return 2;
    zpool_handle_t *pool = zpool_open(hdl, argv[1]);
    zfs_handle_t *dataset = zfs_open(hdl, argv[2], ZFS_TYPE_FILESYSTEM);
    if (!pool || !dataset) {
        if (pool) zpool_close(pool);
        if (dataset) zfs_close(dataset);
        libzfs_fini(hdl);
        return 2;
    }
    char path[16384] = {0};
    zpool_obj_to_path(pool, zfs_prop_get_int(dataset, ZFS_PROP_OBJSETID),
                     st.st_ino, path, sizeof(path));
    printf("%lu\n%s\n", (unsigned long)st.st_nlink, path);
    zfs_close(dataset);
    zpool_close(pool);
    libzfs_fini(hdl);
    return path[0] == '/' ? 0 : 2;
}
