/*
 * vibrator DEVICE: plays rumble effects on an evdev force-feedback device.
 *
 * Reads one decimal number per line on stdin: a duration in milliseconds to
 * rumble for, or 0 to stop. The kernel stops the motor when the duration runs
 * out, and erases the effect, stopping it, when this program exits, so it
 * runs for as long as the Elixir port is open and exits at end of input.
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static int play(int fd, int id, int value)
{
	struct input_event ev;

	memset(&ev, 0, sizeof(ev));
	ev.type = EV_FF;
	ev.code = id;
	ev.value = value;
	return write(fd, &ev, sizeof(ev)) == sizeof(ev) ? 0 : -1;
}

int main(int argc, char *argv[])
{
	struct ff_effect effect;
	char line[32];
	int fd;

	if (argc != 2) {
		fprintf(stderr, "usage: vibrator DEVICE\n");
		return 2;
	}

	fd = open(argv[1], O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "vibrator: open %s: %s\n", argv[1], strerror(errno));
		return 1;
	}

	memset(&effect, 0, sizeof(effect));
	effect.type = FF_RUMBLE;
	effect.id = -1;
	/* gpio-vibrator is on/off: any nonzero magnitude runs the motor. */
	effect.u.rumble.strong_magnitude = 0xffff;

	while (fgets(line, sizeof(line), stdin)) {
		long ms = strtol(line, NULL, 10);

		if (ms <= 0) {
			if (effect.id >= 0 && play(fd, effect.id, 0) < 0)
				goto fail;
			continue;
		}

		/* Uploading with the same id updates the effect in place. */
		effect.replay.length = ms > 0xffff ? 0xffff : ms;
		if (ioctl(fd, EVIOCSFF, &effect) < 0 || play(fd, effect.id, 1) < 0)
			goto fail;
	}

	return 0;

fail:
	fprintf(stderr, "vibrator: %s\n", strerror(errno));
	return 1;
}
