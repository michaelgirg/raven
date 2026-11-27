# Create the RAVEN Ultra96-V2 board prototype project (Phase 5 of
# docs/plans/nahjay_board_prototype.md). From the repository root:
#   vivado -mode batch -source hw/create_project.tcl [-tclargs <options>]
# Options are listed in hw/board_settings.tcl. The project is recreated from scratch under
# <out>/prj (default build/hw/board/prj); open the .xpr in the GUI to inspect
# it. hw/build.tcl runs this first, so a separate call is only needed for inspection.

source [file join [file dirname [info script]] board_settings.tcl]
source [file join [file dirname [info script]] bd.tcl]
raven::parse_args $argv

proc raven::create_board_project {} {
    variable root; variable part; variable project_name; variable bd_name
    variable rtl_sources; variable xdc_sources; variable out0_memory
    variable fixture_dir; variable fixture_images
    check_path_length
    set board [find_board_part]
    set dir [project_dir]
    file mkdir $dir
    create_project -force $project_name $dir -part $part
    set_property board_part $board [current_project]
    set_property target_language Verilog [current_project]
    set_property default_lib xil_defaultlib [current_project]
    puts "RAVEN: part $part, board $board"

    foreach f $rtl_sources {
        set path [file join $root $f]
        if {![file isfile $path]} { error "Missing source $f" }
        add_files -norecurse -fileset sources_1 $path
        if {[file extension $f] eq ".sv"} {
            set_property file_type SystemVerilog [get_files $path]
        }
    }
    if {$out0_memory} {
        # raven_board_top's MEMORY mode names these images by bare file name in $readmemh;
        # synthesis finds them because they are project memory files.
        foreach f $fixture_images {
            set path [file join $root $fixture_dir $f]
            if {![file isfile $path]} { error "Missing fixture image $fixture_dir/$f" }
            add_files -norecurse -fileset sources_1 $path
            set_property file_type {Memory Initialization Files} [get_files $path]
        }
        puts "RAVEN: MEMORY build, fixture $fixture_dir"
    }
    foreach f $xdc_sources {
        add_files -norecurse -fileset constrs_1 [file join $root $f]
    }
    update_compile_order -fileset sources_1

    create_bd
    set bd_file [get_files $bd_name.bd]
    generate_target all $bd_file
    set wrapper [make_wrapper -files $bd_file -top]
    add_files -norecurse -fileset sources_1 $wrapper
    set_property top ${bd_name}_wrapper [get_filesets sources_1]
    update_compile_order -fileset sources_1
    puts "RAVEN_PROJECT_CREATED [file join $dir $project_name.xpr]"
}

raven::create_board_project
