#include "fdebug.h"

module hadapt_extrude
  !!< Extrude a given 2D mesh to a full 3D mesh.
  !!< The layer depths are specified by a sizing function
  !!< which can be arbitrary python.

  use fldebug
  use global_parameters
  use futils, only: int2str
  use quadrature
  use elements
  use spud
  use parallel_tools
  use sparse_tools
  use linked_lists
  use parallel_fields
  use fields
  use vtk_interfaces
  use halos
  use hadapt_combine_meshes

  implicit none

  interface

     subroutine set_from_map(filename, x, y, z, depth, ncolumns, surface_height)
       character (len=*) :: filename
       real, dimension(:) :: x, y, z, depth
       integer :: ncolumns
       real :: surface_height
     end subroutine set_from_map

     subroutine set_from_map_beta(filename, x, y, depth, ncolumns, surface_height)
       character (len=*) :: filename
       real, dimension(:) :: x, y, depth
       integer :: ncolumns
       real :: surface_height
     end subroutine set_from_map_beta

  end interface

  private
  
  public :: extrude, compute_z_nodes, hadapt_extrude_check_options, get_extrusion_options, populate_depth_vector, skip_column_extrude

  interface compute_z_nodes
    module procedure compute_z_nodes_wrapper, compute_z_nodes_sizing
  end interface compute_z_nodes

  contains

  subroutine extrude(h_mesh, option_path, out_mesh)
    !!< The horizontal 2D mesh.
    !!< Note: this must be linear.
    type(vector_field), intent(inout) :: h_mesh
    !!< options to be set for out_mesh,
    !!< at the moment: /name, and under from_mesh/extrude/:
    !!< depth, sizing_function optionally top_surface_id and bottom_surface_id
    character(len=*), intent(in) :: option_path
    !!< The full extruded 3D mesh.
    type(vector_field), intent(out) :: out_mesh

    character(len=FIELD_NAME_LEN):: mesh_name, file_name  
    character(len=OPTION_PATH_LEN):: direction 
    type(quadrature_type) :: quad
    type(element_type) :: full_shape
    type(vector_field) :: constant_z_mesh
    type(vector_field), dimension(:), allocatable :: z_meshes
    character(len=PYTHON_FUNC_LEN) :: sizing_function, depth_function
    real, dimension(:), allocatable :: sizing_vector
    logical:: depth_from_python, depth_from_map, have_min_depth, radial_extrusion
    real, dimension(:), allocatable :: depth_vector
    real:: min_depth, surface_height
    logical:: sizing_is_constant, depth_is_constant, varies_only_in_depth, list_sizing
    real:: constant_sizing, depth, min_bottom_layer_frac
    integer:: h_dim, column, quadrature_degree

    logical :: sigma_layers
    integer :: number_sigma_layers
    
    integer :: n_regions, r
    integer, dimension(:), allocatable :: region_ids
    logical :: apply_region_ids, constant_z_mesh_initialised
    integer, dimension(node_count(h_mesh)) :: visited
    logical, dimension(node_count(h_mesh)) :: column_visited

    !! Checking linearity of h_mesh.
    assert(h_mesh%mesh%shape%degree == 1)
    assert(h_mesh%mesh%continuity >= 0)

    allocate(z_meshes(node_count(h_mesh)))

    call add_nelist(h_mesh%mesh)
    
    n_regions = option_count(trim(option_path)//'/from_mesh/extrude/regions')
    if(n_regions==0) then
      ewrite(-1,*) "I've been told to extrude but have found no regions options."
      FLExit("No regions options found under extrude.")
    elseif(n_regions<0) then
      FLAbort("Negative number of regions options found under extrude.")
    end if
    apply_region_ids = (n_regions>1)
    visited = 0 ! a little debugging check - can be removed later
    
    column_visited = .false.
    
    do r = 0, n_regions-1
      
      constant_z_mesh_initialised = .false.
      
      call get_extrusion_options(option_path, r, apply_region_ids, region_ids, &
                                 depth_is_constant, depth, depth_from_python, depth_function, depth_from_map, direction, &
                                 file_name, have_min_depth, min_depth, surface_height, sizing_is_constant, constant_sizing, list_sizing, &
                                 sizing_function, sizing_vector, min_bottom_layer_frac, varies_only_in_depth, sigma_layers, number_sigma_layers, &
                                 radial_extrusion)

      allocate(depth_vector(size(z_meshes)))
      if (depth_from_map) call populate_depth_vector(h_mesh,file_name,depth_vector,surface_height,radial_extrusion)
      
      ! create a 1d vertical mesh under each surface node
      do column=1, size(z_meshes)
      
        ! decide if this column needs visiting...
        if(skip_column_extrude(h_mesh%mesh, column, &
                              apply_region_ids, column_visited(column), region_ids, &
                              visited_count = visited(column))) cycle
        
        if(varies_only_in_depth .and. depth_is_constant) then
          if (.not. constant_z_mesh_initialised) then
            call compute_z_nodes(constant_z_mesh, node_val(h_mesh, column), min_bottom_layer_frac, &
                            depth_is_constant, depth, depth_from_python, depth_function, &
                            depth_from_map, depth_vector(column),  have_min_depth, min_depth, &
                            sizing_is_constant, constant_sizing, list_sizing, sizing_function, sizing_vector, &
                            sigma_layers, number_sigma_layers, radial_extrusion, direction)
            constant_z_mesh_initialised = .true.
          end if
          call get_previous_z_nodes(z_meshes(column), constant_z_mesh)
        else
          call compute_z_nodes(z_meshes(column), node_val(h_mesh, column), min_bottom_layer_frac, &
                            depth_is_constant, depth, depth_from_python, depth_function, &
                            depth_from_map, depth_vector(column),  have_min_depth, min_depth, &
                            sizing_is_constant, constant_sizing, list_sizing, sizing_function, sizing_vector, &
                            sigma_layers, number_sigma_layers, radial_extrusion, direction)
        end if

      end do
      
      if(apply_region_ids) deallocate(region_ids)
      deallocate(depth_vector)
      
      if (constant_z_mesh_initialised) then
        call deallocate(constant_z_mesh)
      end if
    
    end do
    
#ifdef DDEBUG
    if(apply_region_ids) then
      ewrite(2,*) "Maximum number of times a node was visited: ", maxval(visited)
      ewrite(2,*) "Minimum number of times a node was visited: ", minval(visited)
      if(.not.isparallel()) then
        assert(minval(visited)>0)
      end if
    end if
#endif
      
    ! Now the tiresome business of making a shape function.
    h_dim = mesh_dim(h_mesh)
    call get_option("/geometry/quadrature/degree", quadrature_degree)
    quad = make_quadrature(vertices=h_dim + 2, dim=h_dim + 1, degree=quadrature_degree)
    full_shape = make_element_shape(vertices=h_dim + 2, dim=h_dim + 1, degree=1, quad=quad)
    call deallocate(quad)

    call get_option(trim(option_path)//'/name', mesh_name)

    ! combine the 1d vertical meshes into a full mesh
    call combine_z_meshes(h_mesh, z_meshes, out_mesh, &
       full_shape, mesh_name, option_path, sigma_layers)
       
    do column=1, node_count(h_mesh)
      if (.not. node_owned(h_mesh, column)) cycle
      call deallocate(z_meshes(column))
    end do
    call deallocate(full_shape)
    deallocate(z_meshes)
    
  end subroutine extrude

  subroutine get_extrusion_options(option_path, region_index, apply_region_ids, region_ids, &
                                   depth_is_constant, depth, depth_from_python, depth_function, depth_from_map, direction, &
                                   file_name, have_min_depth, min_depth, surface_height, sizing_is_constant, constant_sizing, list_sizing, &
                                   sizing_function, sizing_vector, min_bottom_layer_frac, varies_only_in_depth, sigma_layers, number_sigma_layers, &
                                   radial_extrusion)

    character(len=*), intent(in) :: option_path
    integer, intent(in) :: region_index
    logical, intent(in) :: apply_region_ids
    
    integer, dimension(:), allocatable :: region_ids
    
    logical, intent(out) :: depth_is_constant, depth_from_python, depth_from_map
    real, intent(out) :: depth
    character(len=PYTHON_FUNC_LEN), intent(out) :: depth_function
    character(len=OPTION_PATH_LEN), intent(out) :: direction
    
    logical, intent(out) :: sizing_is_constant, list_sizing
    real, intent(out) :: constant_sizing
    character(len=PYTHON_FUNC_LEN), intent(out) :: sizing_function
    real, dimension(:), allocatable, intent(out) :: sizing_vector

    character(len=FIELD_NAME_LEN), intent(out) :: file_name
    logical, intent(out) :: have_min_depth
    real, intent(out) :: min_depth, surface_height
    
    logical, intent(out) :: varies_only_in_depth
    
    real, intent(out) :: min_bottom_layer_frac

    logical, intent(out) :: sigma_layers
    integer, intent(out) :: number_sigma_layers

    logical, intent(out) :: radial_extrusion
    
    integer, dimension(2) :: shape_option
    integer :: stat

    radial_extrusion = have_option("/geometry/spherical_earth")

    if(apply_region_ids) then
      shape_option=option_shape(trim(option_path)//"/from_mesh/extrude/regions["//int2str(region_index)//"]/region_ids")
      allocate(region_ids(1:shape_option(1)))
      call get_option(trim(option_path)//"/from_mesh/extrude/regions["//int2str(region_index)//"]/region_ids", region_ids)
    end if

    call get_option(trim(option_path)//&
 	   '/from_mesh/extrude/regions['//int2str(region_index)//&
   	   ']/direction/name', direction, default='top_to_bottom')

    ! get the extrusion options
    depth_from_python=.false.
    depth_from_map=.false.
    have_min_depth=.false.
    call get_option(trim(option_path)//&
                    '/from_mesh/extrude/regions['//int2str(region_index)//&
                    ']/bottom_depth/constant', &
                      depth, stat=stat)
    if (stat==0) then
      depth_is_constant = .true.
    else
      depth_is_constant = .false.
      call get_option(trim(option_path)//&
                      '/from_mesh/extrude/regions['//int2str(region_index)//&
                      ']/bottom_depth/python', &
                       depth_function, stat=stat)
      if (stat==0) depth_from_python = .true.
      if (stat /= 0) then 
        call get_option(trim(option_path)//'/from_mesh/extrude/regions['//int2str(region_index)//&
                         ']/bottom_depth/from_map/file_name', &
                          file_name, stat=stat)
        if (stat==0) depth_from_map = .true.
      end if
      if (stat /= 0) then
        FLAbort("Unknown way of specifying bottom depth function in mesh extrusion")
      end if
    end if

    if (have_option(trim(option_path)//'/from_mesh/extrude/regions['//int2str(region_index)//&
                                         ']/bottom_depth/from_map/min_depth')) then
      have_min_depth=.true.
      call get_option(trim(option_path)//'/from_mesh/extrude/regions['//int2str(region_index)//&
                                         ']/bottom_depth/from_map/min_depth',min_depth)
    end if

    surface_height=0.0
    if (have_option(trim(option_path)//'/from_mesh/extrude/regions['//int2str(region_index)//&
                                         ']/bottom_depth/from_map/surface_height')) then
      call get_option(trim(option_path)//'/from_mesh/extrude/regions['//int2str(region_index)//&
                                         ']/bottom_depth/from_map/surface_height',surface_height)
    end if
    
    list_sizing=.false.
    sigma_layers=.false.
    call get_option(trim(option_path)//&
                    '/from_mesh/extrude/regions['//int2str(region_index)//&
                    ']/sizing_function/constant', &
                    constant_sizing, stat=stat)
    if (stat==0) then
      sizing_is_constant=.true.
    else
      sizing_is_constant=.false.
      call get_option(trim(option_path)//&
                      '/from_mesh/extrude/regions['//int2str(region_index)//&
                      ']/sizing_function/python', &
                      sizing_function, stat=stat)
      if (have_option(trim(option_path)//"/from_mesh/extrude/regions["//&
                                    int2str(region_index)//"]/sizing_function/list")) then
        list_sizing=.true.
        shape_option=option_shape(trim(option_path)//"/from_mesh/extrude/regions["//&
                                       int2str(region_index)//"]/sizing_function/list")
        allocate(sizing_vector(1:shape_option(1)))
        call get_option(trim(option_path)//'/from_mesh/extrude/regions['//&
                                    int2str(region_index)//']/sizing_function/list', &
                                    sizing_vector, stat=stat)
      end if
      if (have_option(trim(option_path)//"/from_mesh/extrude/regions["//&
                                       int2str(region_index)//"]/sizing_function/sigma_layers")) then
        sigma_layers=.true.
        call get_option(trim(option_path)//'/from_mesh/extrude/regions['//&
                                    int2str(region_index)//']/sizing_function/sigma_layers/standard', &
                                    number_sigma_layers, stat=stat)
      end if
      if (stat/=0) then
        FLAbort("Unknown way of specifying sizing function in mesh extrusion")
      end if       
    end if

    varies_only_in_depth = have_option(trim(option_path)//&
    '/from_mesh/extrude/regions['//int2str(region_index)//&
    ']/sizing_function/varies_only_in_depth')
  
    call get_option(trim(option_path)//&
                    '/from_mesh/extrude/regions['//int2str(region_index)//&
                    ']/minimum_bottom_layer_fraction', &
                    min_bottom_layer_frac, default=1.e-3)
  
  end subroutine get_extrusion_options

  subroutine populate_depth_vector(h_mesh,file_name,depth_vector,surface_height,radial_extrusion)

    type(vector_field), intent(in) :: h_mesh
    character(len=FIELD_NAME_LEN), intent(in):: file_name
    real, intent(in) :: surface_height
    real, dimension(:,:), allocatable :: tmp_pos_vector
    real, dimension(:), intent(inout) :: depth_vector
    logical :: radial_extrusion

    integer :: column

    if(radial_extrusion) then

      allocate(tmp_pos_vector(mesh_dim(h_mesh)+1, size(depth_vector)))

      do column=1, node_count(h_mesh)
        tmp_pos_vector(:,column) = node_val(h_mesh, column)
      end do

      call set_from_map(trim(file_name)//char(0), tmp_pos_vector(1,:), tmp_pos_vector(2,:), tmp_pos_vector(3,:), &
                                                                  depth_vector, size(depth_vector), surface_height)

    else

      allocate(tmp_pos_vector(mesh_dim(h_mesh), size(depth_vector)))

      do column=1, node_count(h_mesh)
        tmp_pos_vector(:,column) = node_val(h_mesh, column)
      end do

      call set_from_map_beta(trim(file_name)//char(0), tmp_pos_vector(1,:), tmp_pos_vector(2,:), &
                                                  depth_vector, size(depth_vector), surface_height)

    end if

    if (associated(h_mesh%mesh%halos)) then
      call halo_update(h_mesh%mesh%halos(2), depth_vector)
    end if

    deallocate(tmp_pos_vector)

  end subroutine populate_depth_vector

  subroutine compute_z_nodes_wrapper(z_mesh, xy, min_bottom_layer_frac, &
                                     depth_is_constant, depth, depth_from_python, depth_function, &
                                     depth_from_map, map_depth, have_min_depth, min_depth, &
                                     sizing_is_constant, constant_sizing, list_sizing, sizing_function, sizing_vector, &
                                     sigma_layers, number_sigma_layers, radial_extrusion, direction)

    type(vector_field), intent(out) :: z_mesh
    real, dimension(:), intent(in) :: xy
    real, intent(in) :: min_bottom_layer_frac
    logical, intent(in) :: depth_is_constant, sizing_is_constant, depth_from_python, depth_from_map, list_sizing
    logical, intent(in) :: have_min_depth, sigma_layers
    real, intent(in) :: map_depth, min_depth
    real, intent(in) :: depth, constant_sizing
    character(len=*), intent(in) :: depth_function, sizing_function, direction
    real, dimension(:), intent(in) :: sizing_vector
    integer, intent(in) :: number_sigma_layers
    logical, intent(in) :: radial_extrusion

    real, dimension(1) :: tmp_depth
    real, dimension(size(xy), 1) :: tmp_pos
    real :: ldepth
    
    if(depth_is_constant) then
      ldepth = depth
    else 
      tmp_pos(:,1) = xy
      if (depth_from_python) then
        call set_from_python_function(tmp_depth, trim(depth_function), tmp_pos, time=0.0)
        ldepth = tmp_depth(1)
      else if (depth_from_map) then
         ldepth = map_depth
         if (have_min_depth) then
           if (ldepth < min_depth) ldepth=min_depth
         end if
      else
        FLAbort("Unknown way of specifying the bottom_depth.")
      end if
    end if
    
    if (sizing_is_constant) then
      call compute_z_nodes(z_mesh, ldepth, xy, &
       min_bottom_layer_frac, radial_extrusion, direction, sizing=constant_sizing)
    else
      if (list_sizing) then
        call compute_z_nodes(z_mesh, ldepth, xy, &
        min_bottom_layer_frac, radial_extrusion, direction, sizing_vector=sizing_vector)
      else if (sigma_layers) then
        call compute_z_nodes(z_mesh, ldepth, xy, &
        min_bottom_layer_frac, radial_extrusion, direction, number_sigma_layers=number_sigma_layers)
      else
        call compute_z_nodes(z_mesh, ldepth, xy, &
        min_bottom_layer_frac, radial_extrusion, direction, sizing_function=sizing_function)
      end if
    end if
    
  end subroutine compute_z_nodes_wrapper

  subroutine get_previous_z_nodes(z_mesh, z_mesh_previous)
    type(vector_field), intent(inout) :: z_mesh, z_mesh_previous
    z_mesh = z_mesh_previous
    call incref(z_mesh)
  end subroutine get_previous_z_nodes

  subroutine compute_z_nodes_sizing(z_mesh, depth, xy, min_bottom_layer_frac, &
                                    radial_extrusion, direction, sizing, &
                                    sizing_function, sizing_vector, number_sigma_layers)
    !!< Figure out at what depths to put the layers.
    type(vector_field), intent(out) :: z_mesh
    real, intent(in):: depth
    real, dimension(:), intent(in):: xy
    ! to prevent infinitesimally thin bottom layer if sizing function
    ! is an integer mulitple of total depth, the bottom layer needs
    ! to have at least this fraction of the layer depth above it.
    ! The recommended value is 1e-3.
    real, intent(in) :: min_bottom_layer_frac
    logical, intent(in) :: radial_extrusion
    real, optional, intent(in):: sizing
    character(len=*), intent(in) :: direction
    character(len=*), optional, intent(in):: sizing_function
    real, dimension(:), optional, intent(in) :: sizing_vector
    integer, optional, intent(in) :: number_sigma_layers
    ! this is a safety gap:
    integer, parameter:: MAX_VERTICAL_NODES=1e6

    integer :: elements
    logical :: is_constant
    real :: constant_value

    type(rlist):: depths
    type(mesh_type) :: mesh
    type(element_type) :: oned_shape
    type(quadrature_type) :: oned_quad
    integer :: quadrature_degree
    integer :: ele
    integer, parameter :: loc=2
    integer :: node
    real, dimension(:), allocatable:: xyz
    real, dimension(size(xy)) :: radial_dir
    real :: delta_h, d
    character(len=PYTHON_FUNC_LEN) :: py_func
    integer :: list_size

    call get_option("/geometry/quadrature/degree", quadrature_degree)
    oned_quad = make_quadrature(vertices=loc, dim=1, degree=quadrature_degree)
    oned_shape = make_element_shape(vertices=loc, dim=1, degree=1, quad=oned_quad)
    call deallocate(oned_quad)

    if (present(sizing)) then
      is_constant=.true.
      constant_value=sizing
      py_func = " "
    else if (present(sizing_function)) then
      is_constant=.false.
      constant_value=-1.0
      py_func = sizing_function
    else if (present(sizing_vector)) then
      is_constant=.false.
      constant_value=-1.0
      list_size=size(sizing_vector)
    else if (present(number_sigma_layers)) then
      is_constant=.true.
      constant_value=depth/float(number_sigma_layers)
      py_func = " "
    else
      FLAbort("Need to supply either sizing or sizing_function")
    end if

    ! Start the mesh at d=0 and work down to d=-depth.
    d=0.0
    node=2
    ! first size(xy) coordinates remain fixed, 
    ! the last entry will be replaced with the appropriate depth
    if (radial_extrusion) then
      allocate(xyz(size(xy)))
    else
      allocate(xyz(size(xy)+1))
    end if
    xyz(1:size(xy))=xy
    radial_dir = 0.0
    if (radial_extrusion) radial_dir = xy/sqrt(sum(xy**2))
    call insert(depths, d)
    do
      if (radial_extrusion) then
        xyz = xy - radial_dir*d
      else
        xyz(size(xy)+1)=-d
      end if
      if (present(sizing_vector)) then
        if ((node-1)<=list_size) then
          delta_h = sizing_vector(node-1)
        else
          delta_h = sizing_vector(list_size)
        end if
        node=node+1
      else
        delta_h = get_delta_h( xyz, is_constant, constant_value, py_func)
      end if
      if (trim(direction)=='top_to_bottom') then
      d=d + sign(delta_h, depth)
      if (abs(d)>abs(depth)-min_bottom_layer_frac*delta_h) exit
      else if (trim(direction)=='bottom_up') then
        d=d - delta_h
        if (d < -depth-min_bottom_layer_frac*delta_h) then
          exit
        endif
      endif
      call insert(depths, d)
      if (depths%length>MAX_VERTICAL_NODES) then
        ewrite(-1,*) "Check your extrude/sizing_function"
        FLExit("Maximum number of vertical layers reached")
      end if
    end do
    if (trim(direction)=='top_to_bottom') call insert(depths, depth)
    elements=depths%length-1

    call allocate(mesh, elements+1, elements, oned_shape, "ZMesh")
    do ele=1,elements
      mesh%ndglno((ele-1) * loc + 1: ele*loc) = (/ele, ele+1/)
    end do

    call allocate(z_mesh, 1, mesh, "ZMeshCoordinates")
    call deallocate(mesh)
    call deallocate(oned_shape)

    do node=1, elements+1
      call set(z_mesh, node, (/ -pop(depths) /) )
    end do
    deallocate(xyz)

    ! For pathological sizing functions the mesh might have gotten inverted at the last step.
    ! If you encounter this, make this logic smarter.
    assert(abs(node_val(z_mesh, 1, elements)) < abs(node_val(z_mesh, 1, elements+1)))
    
    assert(oned_quad%refcount%count == 1)
    assert(oned_shape%refcount%count == 1)
    assert(z_mesh%refcount%count == 1)
    assert(mesh%refcount%count == 1)

    contains
    
      function get_delta_h(pos, is_constant, constant_value, py_func) result(delta_h)
        real, dimension(:), intent(in) :: pos
        logical, intent(in) :: is_constant
        real, intent(in) :: constant_value
        character(len=PYTHON_FUNC_LEN), intent(in) :: py_func

        real :: delta_h
        real, dimension(1) :: delta_h_tmp
        real, dimension(size(pos), 1) :: pos_tmp
        
        if (is_constant) then
          delta_h = constant_value
        else
          pos_tmp(:, 1) = pos
          call set_from_python_function(delta_h_tmp, trim(py_func), pos_tmp, time=0.0)
          delta_h = delta_h_tmp(1)
        end if
        assert(delta_h > 0.0)
        
      end function get_delta_h
      
  end subroutine compute_z_nodes_sizing

  logical function skip_column_extrude(horizontal_mesh, column, &
                                       apply_region_ids, column_visited, region_ids, &
                                       visited_count)
    !!< this function decides if a column need extruding or not
    type(mesh_type), intent(in) :: horizontal_mesh
    integer, intent(in) :: column
    logical, intent(in) :: apply_region_ids
    logical, intent(inout) :: column_visited
    integer, dimension(:), intent(in) :: region_ids
    integer, intent(inout), optional :: visited_count
    
    integer, dimension(:), pointer :: eles
    logical :: node_in_region
    integer :: rs
    
    skip_column_extrude = .false.
    if(.not.node_owned(horizontal_mesh, column)) then
      skip_column_extrude = .true.
      return
    end if
    
    ! need to work out here if this column is in one of the current region ids!
    ! this is a bit arbitrary since nodes belong to multiple regions... therefore
    ! the extrusion depth had better be continuous across region id boundaries!
    if(apply_region_ids) then
      if(column_visited) then
        skip_column_extrude = .true.
        return
      end if
      eles => node_neigh(horizontal_mesh, column)
      node_in_region = .false.
      region_id_loop: do rs = 1, size(region_ids)
        if(any(region_ids(rs)==horizontal_mesh%region_ids(eles))) then
          node_in_region = .true.
          exit region_id_loop
        end if
      end do region_id_loop
      if(.not.node_in_region) then
        skip_column_extrude = .true.
        return
      end if
      column_visited=.true.
      if(present(visited_count)) then
        visited_count = visited_count + 1
      end if
    end if
  
  end function skip_column_extrude

  ! hadapt_extrude options checking
  subroutine hadapt_extrude_check_options

    integer :: nmeshes, m, nregions, r
    character(len=OPTION_PATH_LEN) :: mesh_path

    nmeshes=option_count("/geometry/mesh")
    do m = 0, nmeshes-1
      mesh_path="/geometry/mesh["//int2str(m)//"]"
      nregions=option_count(trim(mesh_path)//'/from_mesh/extrude/regions')
      if (nregions>1) then
        ! we're using region ids to extrude
        if (have_option('/mesh_adaptivity/hr_adaptivity') &
           .and. .not. have_option('/mesh_adaptivity/hr_adaptivity/preserve_mesh_regions')) then
          ewrite(-1,*) "You are using region ids to specify mesh extrusion"
          ewrite(-1,*) "However in your adaptivity settings you have not selected " // &
            & "/mesh_adaptivity/hr_adaptivity/preserve_mesh_regions"
          ewrite(-1,*) "This means fluidity will not be able to extrude your mesh again after the adapt."
          FLExit("Missing /mesh_adaptivity/hr_adaptivity/preserve_mesh_regions option")
        end if
      end if   
        
    end do

  end subroutine hadapt_extrude_check_options

    
end module hadapt_extrude
