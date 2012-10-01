preprocess: 
	@echo **********Generating structured meshes using gmsh in 2d:
	gmsh -2 -o mesh/square_24.msh mesh/square_24.geo
	gmsh -2 -o mesh/square_48.msh mesh/square_48.geo

run:
	@echo **********To run this case at a grid resolution of 24x24, use make run_24.
	@echo **********To run this case at a grid resolution of 48x48, use make run_48.

run_24:
	@echo **********Calling fluidity with verbose log output enabled:
	../../bin/fluidity -v2 -l Stokes-square-convection-24.flml

run_48:
	@echo **********Calling fluidity with verbose log output enabled:
	../../bin/fluidity -v2 -l Stokes-square-convection-48.flml

postprocess:
	@echo **********Calling the python plotting scripts:
	./Plot_RMS.py
	./Plot_Nusselt.py

input: clean preprocess

clean:
	@echo **********Cleaning the output from previous fluidity runs:
	rm -rf *.pdf *.stat *.vtu *checkpoint* *.log-0 *.err-0 matrixdump* mesh/*.msh