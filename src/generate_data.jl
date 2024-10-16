
"""
	generate_data()
generate data from the parameters files in `param/` by downloading the pdb files and running Nanoshaper. 
"""
function generate_data()
    data_dir = "$(homedir())/datasets/proteins"
    params = TOML.parsefile("param/param.toml")
    proteins = downloadpdb(params["protein"]["list"])
    project_dir = pwd()

    cd(mktempdir(prefix = "nanoshaper")) do
        cp("$project_dir/param/conf.prm", "conf.prm")
        for prot_path in proteins
            _, prot_name = splitdir(prot_path)
            mesh_name = first(split(prot_name, ".")) * ".off"
            @info "generating surface" mesh_name
            prot = read(prot_path, PDBFormat)
            atoms = extract_balls(Float64, prot)
            open("atoms.xyzr", "w") do io
                print(io, atoms, Import.XYZR{Float64})
            end
            run(pipeline(`Nanoshaper conf.prm`, devnull))
            cp("triangulatedSurf.off", "$data_dir/$mesh_name", force = true)
        end
    end
end
