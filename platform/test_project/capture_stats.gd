extends RefCounted

# Brightness statistics for a captured frame, shared by the smoke scene and the
# benchmark harness. A capture that exists on disk proves nothing: a missing
# import, a failed shader or a dead GPU path all still write a PNG. Contrast
# (range = max - min) is what separates a rendered frame from a blank one.
#
# Sampling every 7th pixel keeps this off the critical path; captures are taken
# after measurement, never during it.

static func of(img: Image) -> Dictionary:
	var w := img.get_width()
	var h := img.get_height()
	img.convert(Image.FORMAT_RGBA8)
	var data := img.get_data()
	var lo := 255
	var hi := 0
	var total := 0.0
	var count := 0
	var step := 4 * 7
	for i in range(0, data.size() - 3, step):
		var luma := (int(data[i]) + int(data[i + 1]) + int(data[i + 2])) / 3
		lo = mini(lo, luma)
		hi = maxi(hi, luma)
		total += float(luma)
		count += 1
	return {
		"width": w,
		"height": h,
		"min": lo,
		"max": hi,
		"mean": snappedf(total / float(maxi(count, 1)), 0.01),
		"range": hi - lo,
	}
