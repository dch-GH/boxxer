package boxxer

import "core:c/libc"
import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:runtime"
import "core:strings"
import "efsw"

ARG_SRC_DIR :: "-src:"
ARG_PKG_NAME :: "-pkg:"
ARG_DLL_NAME :: "-dll:"
VERBOSE_LOGGING :: "-verbose"

LOG :: "[BOXXER]:"

Game_API :: struct {
	init:             proc(),
	update:           proc() -> bool,
	shutdown:         proc(),
	memory:           proc() -> rawptr,
	hot_reloaded:     proc(_: rawptr),
	needs_full_reset: proc() -> bool,
	lib:              dynlib.Library,
	dll_time:         os.File_Time,
	dll_name:         string,
	version:          int,
	needs_reload:     bool,
}

file_watch_callback :: proc "c" (
	watcher: efsw.Watcher,
	watchid: efsw.WatchId,
	dir, filename: cstring,
	action: efsw.Action,
	old_filename: cstring,
	param: rawptr,
) {
	context = runtime.default_context()
	api := transmute(^Game_API)(param)

	// Try to prevent double events.
	if api.needs_reload do return
	fmt.println(LOG, "Hotloading")
	api.needs_reload = true
}

check_efsw_error :: proc() -> (ok: bool) {
	err := efsw.getlasterror()
	if len(err) > 0 {
		fmt.println("EFSW ERROR: ", string(err))
		return false
	}

	return true
}

build_dir: string
verbose_logging_enabled: bool = false
main :: proc() {
	args := os.args
	cwd := os.get_current_directory()

	// The build output of the game should be the same location as boxxer.exe
	build_dir = cwd
	hotload_version := 0

	src_dir: string
	package_name: string
	dll_name: string
	for arg in args {
		if strings.contains(arg, ARG_SRC_DIR) do src_dir, _ = parse_arg(arg, ARG_SRC_DIR)
		if strings.contains(arg, ARG_PKG_NAME) do package_name, _ = parse_arg(arg, ARG_PKG_NAME)
		if strings.contains(arg, ARG_DLL_NAME) do dll_name, _ = parse_arg(arg, ARG_DLL_NAME)
		verbose_logging_enabled = strings.contains(arg, VERBOSE_LOGGING)
	}

	if verbose_logging_enabled {
		fmt.println(LOG, ARG_SRC_DIR, src_dir)
		fmt.println(LOG, ARG_PKG_NAME, package_name)
		fmt.println(LOG, ARG_DLL_NAME, dll_name)
		fmt.println(LOG, VERBOSE_LOGGING, verbose_logging_enabled)
	}

	key := fmt.tprint("\\", package_name, sep = "")
	if verbose_logging_enabled {
		fmt.println(LOG, "Removing substring to get package directory:", key)
	}

	package_parent_dir := strings.trim_suffix(src_dir, key)
	if verbose_logging_enabled do fmt.println(LOG, "Package directory:", package_parent_dir)

	game_compile_command := fmt.caprintf(
		"odin build {0} -build-mode:dll -out:{1}\\{2}.dll",
		package_name,
		cwd,
		dll_name,
	)

	if verbose_logging_enabled do fmt.println(LOG, "Game compile command:", game_compile_command)

	api, h_ok := load_game_api(hotload_version, dll_name)
	if !h_ok {
		fmt.println(LOG, "Loading game API failed. Aborting.")
		return
	}

	hotload_version += 1

	src_dir_cstring := fmt.ctprintf("{0}", src_dir)
	file_watcher := efsw.create(0)
	efsw.addwatch(file_watcher, src_dir_cstring, file_watch_callback, 1, rawptr(&api))
	efsw.watch(file_watcher)

	if check_efsw_error() {
		api.init()
		for {
			if api.needs_full_reset() {
				api.shutdown()
				unload_game_api(api)
				compile_game(package_parent_dir, game_compile_command)
				fresh_api, fresh_ok := load_game_api(0, dll_name)
				if fresh_ok {
					api = fresh_api
					hotload_version = 1
					api.init()
				}
			}

			if !api.update() do break
			if !api.needs_reload do continue

			if verbose_logging_enabled {
				fmt.println(
					LOG,
					"Compiling game in:",
					os.get_current_directory(),
					"Running command:",
					game_compile_command,
				)
			}

			compile_ok := compile_game(package_parent_dir, game_compile_command)
			if !compile_ok {
				api.needs_reload = false
				continue
			}

			new_api, new_h_ok := load_game_api(hotload_version, dll_name)

			if new_h_ok {
				cached_memory := api.memory()
				unload_game_api(api)
				api = new_api
				api.hot_reloaded(cached_memory)
				if verbose_logging_enabled do fmt.println(LOG, "Current hotload version:", hotload_version)
				hotload_version += 1
			}

			api.needs_reload = false
			free_all(context.temp_allocator)
		}
	}

	fmt.println(LOG, "Shutting down.")
	api.shutdown()
	unload_game_api(api)

	check_efsw_error()

	src_dir_cstring = fmt.ctprintf("{0}", src_dir)
	efsw.removewatch(file_watcher, src_dir_cstring)
	efsw.release(file_watcher)

	free_all(context.allocator) // No idea if this one is necessary.
	free_all(context.temp_allocator)
}

load_game_api :: proc(version: int, dll_name: string) -> (Game_API, bool) {
	if verbose_logging_enabled do fmt.println(LOG, "Build dir:", build_dir)

	os.set_current_directory(build_dir)
	dll_time, dll_time_err := os.last_write_time_by_name(fmt.tprintf("{0}.dll", dll_name))

	if dll_time_err != os.ERROR_NONE {
		fmt.println(LOG, "Failed to get last write time of game DLL!")
		fmt.println(LOG, "Error number:", dll_time_err)
		return {}, false
	}

	dll_copy_name := fmt.tprintf("{0}_{1}.dll", dll_name, version)
	original_bytes, read_ok := os.read_entire_file_from_filename(fmt.tprintf("{0}.dll", dll_name))
	if !read_ok {
		fmt.printf("{0} Failed to read {1} when trying to load game API.", dll_copy_name)
		return {}, false
	}

	copy_handle, copy_err := os.open(dll_copy_name, mode = os.O_CREATE | os.O_RDWR)
	copy_ok := copy_err == os.ERROR_NONE

	if copy_ok {
		written, write_err := os.write_string(copy_handle, string(original_bytes))
		write_ok := write_err == os.ERROR_NONE
		fmt.printf("{0} {1} Bytes written. Success: {2}\n", LOG, written, write_ok)
		os.close(copy_handle)
	} else {
		fmt.printf(
			"{0} Failed to copy {1} to {2}\nError code: {3}",
			LOG,
			dll_name,
			dll_copy_name,
			copy_err,
		)
		return {}, false
	}

	lib, lib_ok := dynlib.load_library(dll_copy_name)
	if !lib_ok {
		fmt.printf("{0} dynlib.load_library failed. Aborting.", LOG)
		return {}, false
	}

	api := Game_API {
		init             = cast(proc())(dynlib.symbol_address(lib, "game_init") or_else nil),
		update           = cast(proc(
		) -> bool)(dynlib.symbol_address(lib, "game_update") or_else nil),
		shutdown         = cast(proc())(dynlib.symbol_address(lib, "game_shutdown") or_else nil),
		memory           = cast(proc(
		) -> rawptr)(dynlib.symbol_address(lib, "game_memory") or_else nil),
		hot_reloaded     = cast(proc(
			_: rawptr,
		))(dynlib.symbol_address(lib, "game_hotloaded") or_else nil),
		needs_full_reset = cast(proc(
		) -> bool)(dynlib.symbol_address(lib, "game_needs_full_reset") or_else nil),
		lib              = lib,
		dll_time         = dll_time,
		dll_name         = dll_name,
		version          = version,
	}

	if api.init == nil ||
	   api.update == nil ||
	   api.shutdown == nil ||
	   api.memory == nil ||
	   api.hot_reloaded == nil ||
	   api.needs_full_reset == nil {
		dynlib.unload_library(api.lib)
		fmt.println(LOG, "Game DLL missing required procedure. Aborting.")
		return {}, false
	}
	return api, true
}

unload_game_api :: proc(api: Game_API) {
	os.set_current_directory(build_dir)
	if api.lib != nil {
		unload_ok := dynlib.unload_library(api.lib)
		if unload_ok && verbose_logging_enabled do fmt.println(LOG, "Dynlib unload success.")
	}

	del_err := os.remove(fmt.tprintf("{0}_{1}.dll", api.dll_name, api.version))
	if del_err != os.ERROR_NONE {
		fmt.printf("{0} Failed to remove {1}_{2}.dll copy\n", LOG, api.dll_name, api.version)
	}
}

parse_arg :: proc(arg: string, cmd: string) -> (parsed: string, ok: bool) {
	parsed = strings.trim_space(strings.trim_prefix(arg, cmd))
	return parsed, true
}

compile_game :: proc(pkg_parent_dir: string, cmd: cstring) -> (ok: bool) {
	os.set_current_directory(pkg_parent_dir)
	{
		// NOTE: This is for when (sometimes) running the odin build command results in a strange
		// Syntax Error, where Odin complains about main.odin missing even though its not? 
		// Maybe EFSW has a lock on it in the thread when Odin tries to compile the package?
		MAX_COMPILE_ATTEMPTS :: 2
		num_attempts := 0
		for compile_cmd_result := libc.system(cmd); compile_cmd_result != 0; {
			libc.system(cmd)
			if num_attempts >= MAX_COMPILE_ATTEMPTS {
				return false
			}
			num_attempts += 1
		}
		return true
	}
}
