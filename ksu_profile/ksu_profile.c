#include <errno.h>
#include <linux/types.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#define KSU_INSTALL_MAGIC1 0xDEADBEEF
#define KSU_INSTALL_MAGIC2 0xCAFEBABE
#define KSU_APP_PROFILE_VER 4
#define KSU_MAX_PACKAGE_NAME 256
#define KSU_MAX_GROUPS 32
#define KSU_SELINUX_DOMAIN 64

#define KSU_IOCTL_UID_SHOULD_UMOUNT _IOC(_IOC_READ | _IOC_WRITE, 'K', 9, 0)
#define KSU_IOCTL_GET_MANAGER_APPID _IOC(_IOC_READ, 'K', 10, 0)
#define KSU_IOCTL_GET_APP_PROFILE _IOC(_IOC_READ | _IOC_WRITE, 'K', 11, 0)
#define KSU_IOCTL_SET_APP_PROFILE _IOC(_IOC_WRITE, 'K', 12, 0)

struct root_profile {
	__s32 uid;
	__s32 gid;
	__u32 groups_count;
	__s32 groups[KSU_MAX_GROUPS];
	struct {
		__u64 effective;
		__u64 permitted;
		__u64 inheritable;
	} capabilities;
	char selinux_domain[KSU_SELINUX_DOMAIN];
	__s32 namespaces;
	__u64 flags;
};

struct non_root_profile {
	bool umount_modules;
};

struct app_profile {
	__u32 version;
	char key[KSU_MAX_PACKAGE_NAME];
	__s32 curr_uid;
	bool allow_su;
	union {
		struct {
			bool use_default;
			char template_name[KSU_MAX_PACKAGE_NAME];
			struct root_profile profile;
		} rp_config;
		struct {
			bool use_default;
			struct non_root_profile profile;
		} nrp_config;
	};
};

struct ksu_uid_should_umount_cmd {
	__u32 uid;
	__u8 should_umount;
};

struct ksu_get_manager_appid_cmd {
	__u32 appid;
};

static int fail(const char *what) {
	fprintf(stderr, "ksu_profile: %s: %s\n", what, strerror(errno));
	return 1;
}

int main(int argc, char *argv[]) {
	if (argc != 3) {
		fprintf(stderr, "Usage: %s <uid> <package>\n", argv[0]);
		return 2;
	}
	__u32 uid = (__u32)strtoul(argv[1], NULL, 10);
	const char *pkg = argv[2];
	if (strlen(pkg) >= KSU_MAX_PACKAGE_NAME) {
		fprintf(stderr, "ksu_profile: package name too long\n");
		return 2;
	}

	int fd = -1;
	syscall(SYS_reboot, KSU_INSTALL_MAGIC1, KSU_INSTALL_MAGIC2, 0, &fd);
	if (fd < 0) return fail("KernelSU is not available");

	struct ksu_uid_should_umount_cmd umount_cmd = {.uid = uid};
	if (ioctl(fd, KSU_IOCTL_UID_SHOULD_UMOUNT, &umount_cmd) < 0) return fail("UID_SHOULD_UMOUNT");
	if (!umount_cmd.should_umount) return 0;

	struct ksu_get_manager_appid_cmd appid_cmd = {0};
	if (ioctl(fd, KSU_IOCTL_GET_MANAGER_APPID, &appid_cmd) < 0) return fail("GET_MANAGER_APPID");
	if (setuid(appid_cmd.appid) != 0) return fail("setuid to manager");

	struct app_profile profile = {0};
	profile.curr_uid = (__s32)uid;
	if (ioctl(fd, KSU_IOCTL_GET_APP_PROFILE, &profile) < 0) {
		if (errno != ENOENT) return fail("GET_APP_PROFILE");
		memset(&profile, 0, sizeof(profile));
		profile.version = KSU_APP_PROFILE_VER;
		strncpy(profile.key, pkg, sizeof(profile.key) - 1);
		profile.curr_uid = (__s32)uid;
	} else if (profile.version != KSU_APP_PROFILE_VER) {
		fprintf(stderr, "ksu_profile: unsupported app profile version %u\n", profile.version);
		return 1;
	} else if (profile.allow_su) {
		fprintf(stderr, "ksu_profile: %s has root access, not changing its profile\n", pkg);
		return 1;
	}

	profile.nrp_config.use_default = false;
	profile.nrp_config.profile.umount_modules = false;
	if (ioctl(fd, KSU_IOCTL_SET_APP_PROFILE, &profile) < 0) return fail("SET_APP_PROFILE");
	return 0;
}
