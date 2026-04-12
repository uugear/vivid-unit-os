// SPDX-License-Identifier: GPL-2.0+
/*
 * JH550172Q MIPI-DSI LCD panel driver for Vivid Unit
 */

#include <backlight.h>
#include <dm.h>
#include <errno.h>
#include <mipi_dsi.h>
#include <panel.h>
#include <asm/gpio.h>
#include <dm/device_compat.h>
#include <linux/delay.h>
#include <power/regulator.h>
#include <stdio.h>

struct panel_init_cmd {
	u8 dtype;
	u8 wait;
	u8 dlen;
	const u8 *data;
};

struct jh550172q_priv {
	struct udevice *reg;
	struct udevice *backlight;
	struct gpio_desc reset;
};

#define JH_LOG(fmt, ...) printf("jh550172q: " fmt "\n", ##__VA_ARGS__)

#define JH_CMD(_dtype, _wait, ...) \
	{ .dtype = (_dtype), .wait = (_wait), .dlen = sizeof((u8[]){ __VA_ARGS__ }), .data = (u8[]){ __VA_ARGS__ } }

static const struct display_timing jh550172q_timing = {
	.pixelclock.typ		= 68000000,
	.hactive.typ		= 720,
	.hfront_porch.typ	= 50,
	.hback_porch.typ	= 50,
	.hsync_len.typ		= 50,
	.vactive.typ		= 1280,
	.vfront_porch.typ	= 10,
	.vback_porch.typ	= 4,
	.vsync_len.typ		= 4,
	.flags			= DISPLAY_FLAGS_HSYNC_LOW | DISPLAY_FLAGS_VSYNC_LOW,
};

static const struct panel_init_cmd jh550172q_init_cmds[] = {
	JH_CMD(MIPI_DSI_DCS_LONG_WRITE, 0, 0xff, 0x98, 0x81, 0x03),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x01, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x02, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x03, 0x53),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x04, 0x53),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x05, 0x13),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x06, 0x04),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x07, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x08, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x09, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x0a, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x0b, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x0c, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x0d, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x0e, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x0f, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x10, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x11, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x12, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x13, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x14, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x15, 0x08),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x16, 0x10),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x17, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x18, 0x08),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x19, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x1a, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x1b, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x1c, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x1d, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x1e, 0xc0),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x1f, 0x80),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x20, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x21, 0x09),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x22, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x23, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x24, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x25, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x26, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x27, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x28, 0x55),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x29, 0x03),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x2a, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x2b, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x2c, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x2d, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x2e, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x2f, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x30, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x31, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x32, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x33, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x34, 0x04),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x35, 0x05),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x36, 0x05),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x37, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x38, 0x3c),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x39, 0x35),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x3a, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x3b, 0x40),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x3c, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x3d, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x3e, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x3f, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x40, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x41, 0x88),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x42, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x43, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x44, 0x1f),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x50, 0x01),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x51, 0x23),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x52, 0x45),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x53, 0x67),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x54, 0x89),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x55, 0xab),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x56, 0x01),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x57, 0x23),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x58, 0x45),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x59, 0x67),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x5a, 0x89),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x5b, 0xab),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x5c, 0xcd),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x5d, 0xef),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x5e, 0x03),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x5f, 0x14),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x60, 0x15),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x61, 0x0c),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x62, 0x0d),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x63, 0x0e),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x64, 0x0f),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x65, 0x10),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x66, 0x11),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x67, 0x08),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x68, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x69, 0x0a),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x6a, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x6b, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x6c, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x6d, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x6e, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x6f, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x70, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x71, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x72, 0x06),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x73, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x74, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x75, 0x14),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x76, 0x15),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x77, 0x0f),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x78, 0x0e),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x79, 0x0d),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x7a, 0x0c),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x7b, 0x11),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x7c, 0x10),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x7d, 0x06),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x7e, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x7f, 0x0a),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x80, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x81, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x82, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x83, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x84, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x85, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x86, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x87, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x88, 0x08),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x89, 0x02),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x8a, 0x02),

	JH_CMD(MIPI_DSI_DCS_LONG_WRITE, 0, 0xff, 0x98, 0x81, 0x04),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x70, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x71, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x66, 0xfe),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x82, 0x15),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x84, 0x15),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x85, 0x15),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x3a, 0x24),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x32, 0xac),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x8c, 0x80),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x3c, 0xf5),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x88, 0x33),

	JH_CMD(MIPI_DSI_DCS_LONG_WRITE, 0, 0xff, 0x98, 0x81, 0x01),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x22, 0x0a),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x31, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x53, 0x80),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x55, 0x88),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x50, 0x5b),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x51, 0x5b),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x60, 0x1b),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x61, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x62, 0x0d),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x63, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0xa0, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0xa1, 0x1d),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0xa2, 0x2a),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0xa3, 0x14),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0xa4, 0x18),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0xa5, 0x2b),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0xa6, 0x1f),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0xa7, 0x1f),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0xa8, 0x81),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0xa9, 0x1b),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0xaa, 0x27),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0xab, 0x6b),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0xac, 0x17),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0xad, 0x13),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0xae, 0x48),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0xaf, 0x1e),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0xb0, 0x26),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0xb1, 0x57),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0xb2, 0x69),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0xb3, 0x39),

	JH_CMD(MIPI_DSI_DCS_LONG_WRITE, 0, 0xff, 0x98, 0x81, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 0, 0x35, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 120, 0x11, 0x00),
	JH_CMD(MIPI_DSI_DCS_SHORT_WRITE_PARAM, 20, 0x29, 0x00),
};

static int jh550172q_init_sequence(struct udevice *dev)
{
	struct mipi_dsi_panel_plat *plat = dev_get_plat(dev);
	struct mipi_dsi_device *device = plat->device;
	struct jh550172q_priv *priv = dev_get_priv(dev);
	unsigned int i;
	int ret;

	JH_LOG("init sequence begin (%u commands)",
	       (unsigned int)ARRAY_SIZE(jh550172q_init_cmds));

	for (i = 0; i < ARRAY_SIZE(jh550172q_init_cmds); i++) {
		const struct panel_init_cmd *cmd = &jh550172q_init_cmds[i];

		ret = mipi_dsi_dcs_write_buffer(device, cmd->data, cmd->dlen);
		if (ret < 0) {
			JH_LOG("init cmd %u failed: ret=%d reg=0x%02x len=%u",
			       i, ret, cmd->data[0], cmd->dlen);
			if (dm_gpio_is_valid(&priv->reset)) {
				JH_LOG("asserting reset after init failure");
				dm_gpio_set_value(&priv->reset, true);
				mdelay(20);
			}
			return ret;
		}

		if (cmd->data[0] == 0x11)
			JH_LOG("sleep out command executed (cmd=%u, wait=%u ms)", i, cmd->wait);
		if (cmd->data[0] == 0x29)
			JH_LOG("display on command executed (cmd=%u, wait=%u ms)", i, cmd->wait);

		if (cmd->wait)
			mdelay(cmd->wait);
	}

	JH_LOG("init sequence complete");
	return 0;
}

static int jh550172q_panel_enable_backlight(struct udevice *dev)
{
	struct mipi_dsi_panel_plat *plat = dev_get_plat(dev);
	struct mipi_dsi_device *device = plat->device;
	struct jh550172q_priv *priv = dev_get_priv(dev);
	int ret;

	JH_LOG("enable_backlight begin");
	if (!device) {
		JH_LOG("enable_backlight aborted: no MIPI DSI device");
		return -ENODEV;
	}

	ret = mipi_dsi_attach(device);
	JH_LOG("mipi_dsi_attach returned %d", ret);
	if (ret && ret != -EALREADY) {
		if (dm_gpio_is_valid(&priv->reset)) {
			JH_LOG("asserting reset after attach failure");
			dm_gpio_set_value(&priv->reset, true);
			mdelay(20);
		}
		return ret;
	}

	ret = jh550172q_init_sequence(dev);
	if (ret) {
		JH_LOG("enable_backlight aborted: init sequence ret=%d", ret);
		return ret;
	}

	if (priv->backlight) {
		ret = backlight_enable(priv->backlight);
		JH_LOG("backlight enable returned %d", ret);
		if (ret)
			return ret;
	} else {
		JH_LOG("backlight enable skipped: no backlight device");
	}

	JH_LOG("enable_backlight end");
	return 0;
}

static int jh550172q_panel_get_display_timing(struct udevice *dev,
					      struct display_timing *timings)
{
	memcpy(timings, &jh550172q_timing, sizeof(*timings));
	JH_LOG("get_display_timing: %ux%u pixclock=%u flags=0x%x",
	       timings->hactive.typ, timings->vactive.typ,
	       timings->pixelclock.typ, timings->flags);
	return 0;
}

static int jh550172q_panel_of_to_plat(struct udevice *dev)
{
	struct jh550172q_priv *priv = dev_get_priv(dev);
	int ret;

	JH_LOG("of_to_plat begin");

	ret = gpio_request_by_name(dev, "reset-gpios", 0, &priv->reset,
				   GPIOD_IS_OUT);
	if (ret) {
		JH_LOG("reset GPIO request failed: %d", ret);
		if (ret != -ENOENT)
			return ret;
	} else if (dm_gpio_is_valid(&priv->reset)) {
		JH_LOG("reset GPIO acquired");
	} else {
		JH_LOG("reset GPIO not present");
	}

	if (CONFIG_IS_ENABLED(DM_REGULATOR)) {
		ret = device_get_supply_regulator(dev, "power-supply", &priv->reg);
		if (ret && ret != -ENOENT) {
			JH_LOG("power supply lookup failed: %d", ret);
			return ret;
		}
		if (!ret)
			JH_LOG("power supply regulator acquired");
		else
			JH_LOG("power supply regulator absent in U-Boot DT");
	}

	ret = uclass_get_device_by_phandle(UCLASS_PANEL_BACKLIGHT, dev,
				   "backlight", &priv->backlight);
	if (ret == -ENOENT)
		ret = 0;
	if (ret) {
		JH_LOG("backlight lookup failed: %d", ret);
		return ret;
	}

	if (priv->backlight)
		JH_LOG("backlight device acquired");
	else
		JH_LOG("backlight device not present");

	JH_LOG("of_to_plat end");
	return 0;
}


static int jh550172q_panel_probe(struct udevice *dev)
{
	struct jh550172q_priv *priv = dev_get_priv(dev);
	struct mipi_dsi_panel_plat *plat = dev_get_plat(dev);
	int ret;

	JH_LOG("panel probe begin");

	if (CONFIG_IS_ENABLED(DM_REGULATOR) && priv->reg) {
		ret = regulator_set_enable(priv->reg, true);
		JH_LOG("panel supply enable returned %d", ret);
		if (ret && ret != -EALREADY)
			return ret;
	} else {
		JH_LOG("panel supply enable skipped");
	}

	if (dm_gpio_is_valid(&priv->reset)) {
		JH_LOG("asserting reset GPIO high");
		dm_gpio_set_value(&priv->reset, true);
		mdelay(20);
		JH_LOG("deasserting reset GPIO low");
		dm_gpio_set_value(&priv->reset, false);
		mdelay(20);
		JH_LOG("reset sequence executed");
	} else {
		JH_LOG("reset sequence skipped: no reset GPIO");
	}

	plat->lanes = 4;
	plat->format = MIPI_DSI_FMT_RGB888;
	plat->mode_flags = MIPI_DSI_MODE_VIDEO |
			   MIPI_DSI_MODE_VIDEO_BURST;

	JH_LOG("panel probe end: lanes=%u format=RGB888 flags=0x%lx (VIDEO|BURST, HSYNC/VSYNC low)",
	       plat->lanes, (ulong)plat->mode_flags);
	return 0;
}

static const struct panel_ops jh550172q_panel_ops = {
	.enable_backlight = jh550172q_panel_enable_backlight,
	.get_display_timing = jh550172q_panel_get_display_timing,
};

static const struct udevice_id jh550172q_panel_ids[] = {
	{ .compatible = "rk3399-vivid-unit,jh550172q" },
	{ }
};

U_BOOT_DRIVER(jh550172q_panel) = {
	.name		= "jh550172q_panel",
	.id		= UCLASS_PANEL,
	.of_match	= jh550172q_panel_ids,
	.ops		= &jh550172q_panel_ops,
	.of_to_plat	= jh550172q_panel_of_to_plat,
	.probe		= jh550172q_panel_probe,
	.plat_auto	= sizeof(struct mipi_dsi_panel_plat),
	.priv_auto	= sizeof(struct jh550172q_priv),
};
