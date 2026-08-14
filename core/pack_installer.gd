# The one way a resource pack gets mounted, shared by both namespaces that have
# packs: CouchGames.experience (bytes the platform already downloaded) and
# CouchGames.game (bytes fetched from the build root on demand). Two sourcing
# strategies, one `bytes -> user:// -> load_resource_pack()` path, so the two
# cannot drift apart.
#
# What is mounted is tracked STATICALLY, because load_resource_pack() is a
# process-global effect: the pack stays mounted across scene reloads, so a
# per-instance record would forget something that is still true. Not
# re-mounting matters — load_resource_pack() replaces files, and a second call
# would silently reshuffle what an already-loaded scene resolved.
class_name CouchPackInstaller

static var _mounted: Dictionary = {}


## True once install() has mounted this destination in this process.
static func is_mounted(mount_path: String) -> bool:
	return _mounted.has(mount_path)


## Stages bytes at mount_path and hands them to the resource system, so the
## pack's contents become available at their own res:// paths. Idempotent: a
## destination already mounted is a no-op returning true.
##
## `label` names the pack in error messages — the caller's name for it, which
## is more use to a game dev than the user:// path it happens to be staged at.
static func install(bytes: PackedByteArray, mount_path: String, label: String) -> bool:
	if _mounted.has(mount_path):
		return true
	if bytes.is_empty():
		push_error("CouchGames: '%s' is empty, nothing to load" % label)
		return false

	var dir := mount_path.get_base_dir()
	var dir_error := DirAccess.make_dir_recursive_absolute(dir)
	if dir_error != OK and not DirAccess.dir_exists_absolute(dir):
		push_error("CouchGames: cannot create '%s': %s" % [dir, error_string(dir_error)])
		return false

	var file := FileAccess.open(mount_path, FileAccess.WRITE)
	if file == null:
		push_error("CouchGames: cannot write '%s': %s"
			% [mount_path, error_string(FileAccess.get_open_error())])
		return false
	# A short write must not fall through to load_resource_pack(): mounting a
	# truncated file reports "is not a loadable resource pack", which blames the
	# pack for a write failure. On web user:// is IndexedDB-backed, so a large
	# pack hitting the storage quota is the realistic way this happens, and this
	# is the message the dev will be reading.
	if not file.store_buffer(bytes):
		var write_error := file.get_error()
		file.close()
		# Don't leave the partial file behind eating the quota that just ran out.
		DirAccess.remove_absolute(mount_path)
		push_error("CouchGames: cannot write %d bytes to '%s': %s"
			% [bytes.size(), mount_path, error_string(write_error)])
		return false
	file.close()

	if not ProjectSettings.load_resource_pack(mount_path):
		push_error("CouchGames: '%s' is not a loadable resource pack" % label)
		return false
	_mounted[mount_path] = true
	return true
