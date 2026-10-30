/******************************************************************************
 Winbond Electronics Corporation
 Verilog Simulation for W25Q16JV series Serial Flash Memory
 (Modified for strict Verilator compatibility - Removed all task disables)
 ******************************************************************************/
/* verilator lint_off VARHIDDEN */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off BLKSEQ */

`timescale 1ns / 1ns

module W25Q16JV (CSn, CLK, DIO, DO, WPn, HOLDn);
input CSn, CLK;
inout DIO;
inout WPn;
inout HOLDn;
inout DO;

parameter NUM_PAGES = 8192;
parameter NUM_SEC_PAGES = 4;
parameter PAGESIZE  = 256;
parameter SECTORSIZE = 4096;
parameter HALFBLOCKSIZE = 32768;
parameter BLOCKSIZE = 65536;
parameter NUM_BLOCKS = NUM_PAGES * PAGESIZE / BLOCKSIZE;
parameter NUM_LOCKBITS = NUM_BLOCKS - 2 + 32;
parameter MANUFACTURER = 8'hEF;
parameter DEVICE_ID	= 8'h14;
parameter JEDEC_ID_HI = 8'h40;
parameter JEDEC_ID_HI_QPI = 8'h70;
parameter JEDEC_ID_LO = 8'h15;
parameter UNIQUE_ID = 64'h0102030405060708;
parameter ADDRESS_MASK = (NUM_PAGES * PAGESIZE) - 1;

`define MEM_FILENAME "MEM.TXT"		
`define SECSI_FILENAME "SECSI.TXT"
`define SFDP_FILENAME "SFDP.TXT"
`define SREG_FILENAME "SREG.TXT"

reg [7:0] memory [0:(NUM_PAGES * PAGESIZE) - 1];	
reg [7:0] page_latch [0:PAGESIZE-1];                 
reg [7:0] secsi[0:(NUM_SEC_PAGES * (SECTORSIZE/PAGESIZE) * PAGESIZE) - 1]; 
reg [7:0] sfdp[0:PAGESIZE];                                                

reg lock_array[0:NUM_LOCKBITS];                                            

reg [23:0] status_reg;				      
reg [23:0] status_reg_shadow;			
reg status_reg_otp [23:0];      
reg [23:0] byte_address;				    
reg [23:0] prog_byte_address;   
reg [7:0] mode_reg;					        
reg [7:0] wrap_reg;             
reg [7:0] read_param_reg;        
reg [7:0] read_param_reg_shadow; 

reg flag_prog_page;         			 
reg flag_prog_secsi_page;        
reg flag_erase_sector;				      
reg flag_erase_secsi_sector;
reg flag_erase_half_block;			   
reg flag_erase_block;				       
reg flag_erase_bulk;				        
reg flag_power_up_exec;
reg flag_power_down;
reg flag_power_up_sig_read;
reg flag_write_status_reg;
reg flag_suspend;               
reg flag_resume;                
reg flag_suspend_enabled;       
reg flag_slow_read_reg;
reg flag_volatile_sr_write;     
wire flag_slow_read = flag_slow_read_reg;

reg flag_read_op_reg;
wire #1 flag_read_op = flag_read_op_reg;   

reg flag_qpi_mode;             

reg flag_enable_reset;         
reg flag_reset;                
reg flag_reset_condition;      
reg flag_set_read_param;       

reg timing_error;					         

reg [7:0] in_byte;					        
reg [7:0] out_byte;

reg WPn_Reg, WPn_Output_Enable_reg; 
wire WPn_Output_Enable = WPn_Output_Enable_reg;

reg HOLDn_Reg, HOLDn_Output_Enable; 

reg DO_Reg, DO_Output_Enable, temp_DO_Output_Enable;

reg DIO_Reg, DIO_Output_Enable_reg, temp_DIO_Output_Enable_reg;
wire DIO_Output_Enable = DIO_Output_Enable_reg;

reg HOLDn_Active;

reg [7:0]  cmd_byte;
reg [7:0]  null_reg;
reg [7:0]  temp;

integer    x;
integer	 fileno;
reg [15:0] file_sector;
reg [15:0] file_length;

`define CMD_WRITE_DISABLE 			      	8'h04
`define CMD_WRITE_ENABLE  			      	8'h06
`define CMD_READ_STATUS				        8'h05
`define CMD_WRITE_STATUS				8'h01
`define CMD_READ_STATUS2				8'h35
`define CMD_WRITE_STATUS2          			8'h31
`define CMD_READ_STATUS3           			8'h15
`define CMD_WRITE_STATUS3          			8'h11
`define CMD_READ_DATA				        8'h03
`define CMD_READ_DATA_FAST			      	8'h0b
`define CMD_READ_DATA_FAST_WRAP    			8'h0c
`define CMD_READ_DATA_FAST_DUAL		  		8'h3b
`define CMD_READ_DATA_FAST_DUAL_IO			8'hbb
`define CMD_READ_DATA_FAST_QUAD		  		8'h6b
`define CMD_READ_DATA_FAST_QUAD_IO			8'heb
`define CMD_READ_OCTAL_FAST_QUAD_IO 			8'he3
`define CMD_READ_WORD_FAST_QUAD_IO 			8'he7
`define CMD_PAGE_PROGRAM				8'h02
`define CMD_PAGE_PROGRAM_QUAD			   	8'h32
`define CMD_BLOCK_ERASE				        8'hD8
`define CMD_HALF_BLOCK_ERASE			    	8'h52
`define CMD_SECTOR_ERASE				8'h20
`define CMD_BULK_ERASE				        8'hC7
`define CMD_BULK_ERASE2				        8'h60
`define CMD_DEEP_POWERDOWN			      	8'hB9
`define CMD_READ_SIGNATURE			      	8'hAB
`define CMD_READ_ID					8'h90
`define CMD_READ_ID_DUAL           			8'h92
`define CMD_READ_ID_QUAD           			8'h94
`define CMD_READ_JEDEC_ID			       	8'h9f
`define CMD_READ_UNIQUE_ID			      	8'h4b
`define CMD_SUSPEND                			8'h75
`define CMD_RESUME                 			8'h7A
`define CMD_SET_BURST_WRAP         			8'h77
`define CMD_MODE_RESET             			8'hff
`define CMD_DISABLE_QPI            			8'hff
`define CMD_ENABLE_QPI             			8'h38
`define CMD_ENABLE_RESET           			8'h66
`define CMD_CHIP_RESET             			8'h99
`define CMD_SET_READ_PARAM         			8'hC0
`define CMD_SREG_PROGRAM           			8'h42
`define CMD_SREG_ERASE             			8'h44
`define CMD_SREG_READ              			8'h48
`define CMD_WRITE_ENABLE_VSR       			8'h50
`define CMD_READ_SFDP              			8'h5A
`define CMD_INDIVIDUAL_LOCK        			8'h36
`define CMD_INDIVIDUAL_UNLOCK      			8'h39
`define CMD_READ_BLOCK_LOCK        			8'h3D
`define CMD_GLOBAL_BLOCK_LOCK      			8'h7E
`define CMD_GLOBAL_BLOCK_UNLOCK    			8'h98

`define STATUS_HLD_RST   				24'h800000
`define STATUS_DRV1      				24'h400000
`define STATUS_DRV0      				24'h200000
`define STATUS_WPS       				24'h040000
`define STATUS_SUS       				24'h008000
`define STATUS_CMP       				24'h004000
`define STATUS_LB3       				24'h002000
`define STATUS_LB2       				24'h001000
`define STATUS_LB1       				24'h000800
`define STATUS_QE					24'h000200
`define STATUS_SRP1					24'h000100
`define STATUS_SRP0					24'h000080
`define STATUS_SEC 					24'h000040
`define STATUS_TB				   	24'h000020
`define STATUS_BP2					24'h000010
`define STATUS_BP1					24'h000008
`define STATUS_BP0	   				24'h000004
`define STATUS_WEL		 			24'h000002
`define STATUS_WIP	 				24'h000001

`define HLD_RST 					23
`define DRV1 						22
`define DRV0 						21
`define WPS  						18
`define SUS  						15
`define CMP 						14
`define LB3  						13
`define LB2  						12
`define LB1  						11
`define QE	  					9
`define SRP1						8
`define SRP0						7
`define SEC 	 					6
`define TB  						5
`define BP2	 					4
`define BP1	 					3
`define BP0	 					2
`define WEL	 					1
`define WIP	 					0

wire flag_quad_mode = status_reg[`QE];
wire flag_quad_mode_cs = !flag_quad_mode & !CSn;

specify
specparam 1000 = 1000;      
specparam	tSLCH = 5;					
$setup(negedge CSn, posedge CLK, tSLCH, timing_error); 
specparam tCHSL = 5;					
$setup(posedge CLK, negedge CSn, tCHSL, timing_error);
specparam	tSHSL_R = 10;					
specparam tSHSL_W = 50;
$width(posedge CSn &&& flag_read_op, tSHSL_R, 0, timing_error);
$width(posedge CSn &&& (~flag_read_op), tSHSL_W, 0, timing_error);
specparam tCHSH = 3;
$setup(posedge CLK, posedge CSn, tCHSH, timing_error);
specparam tSHCH = 3;
$setup(posedge CSn, posedge CLK, tSHCH, timing_error);

specparam	tCYC = 9;				       
specparam	tCLH  = 4;				       
specparam tCLL  = 4;		        	
$period(posedge CLK &&& (~flag_slow_read), tCYC, timing_error);
$width(posedge CLK &&& (~flag_slow_read), tCLH, 0, timing_error);
$width(negedge CLK &&& (~flag_slow_read), tCLL, 0, timing_error);

specparam tCYCR = 20;				      
specparam	tCRLH  = 8;				      
specparam tCRLL  = 8;		        
$period(posedge CLK &&& (flag_slow_read), tCYCR, timing_error);
$width(posedge CLK &&& (flag_slow_read), tCRLH, 0, timing_error);
$width(negedge CLK &&& (flag_slow_read), tCRLL, 0, timing_error);

specparam	tDVCH = 2;				
specparam	tCHDX = 3;    
$setup(DIO, posedge CLK &&& (~DIO_Output_Enable), tDVCH, timing_error);
$hold(posedge CLK, DIO &&& (~DIO_Output_Enable), tCHDX, timing_error);

specparam tWHSL = 20;
specparam tSHWL = 100;

specparam tHLQZ = 12;
specparam tHHQX = 7;
specparam 20000 = 20000;

specparam tCHHL = 5;
$setup(posedge CLK, negedge HOLDn &&& (flag_quad_mode_cs),tCHHL, timing_error);
specparam tHLCH = 5;           
$hold(posedge CLK, negedge HOLDn &&& (flag_quad_mode_cs),tHLCH, timing_error);
specparam tCHHH = 5;
$setup(posedge CLK, posedge HOLDn &&& (flag_quad_mode_cs),tCHHH, timing_error);
specparam tHHCH = 5;               
$hold(posedge CLK, posedge HOLDn &&& (flag_quad_mode_cs), tHHCH, timing_error);
endspecify

parameter 	tCLQV =  6;				      
parameter	tSHQZ =  7;				      
parameter	tW =     10000000;			
parameter 	tRES1 =  3000;				  
parameter	tRES2 =  1800;			   
parameter	tDP =    3000;				   
parameter	tPP =    400000;			  
parameter	tSE =    45000000;		 
parameter 	tBE1 =   120000000;		
parameter 	tBE2 =   150000000;		
parameter	tCE_20 = 250000000;	

initial
begin :initialization
  $readmemh(`MEM_FILENAME,memory);
  $readmemh(`SECSI_FILENAME,secsi);
  $readmemh(`SFDP_FILENAME,sfdp);
  $readmemh(`SREG_FILENAME,status_reg_otp);
  chip_reset();
end

assign DIO = DIO_Output_Enable_reg ? DIO_Reg : 1'bz;
assign DO = DO_Output_Enable ? DO_Reg : 1'bz;
assign WPn = WPn_Output_Enable_reg ? WPn_Reg : 1'bz;
assign HOLDn = HOLDn_Output_Enable ? HOLDn_Reg : 1'bz;

always @(negedge CSn)				    
begin :read_opcode

  flag_read_op_reg = 1'b1;   
	mode_reg = mode_reg & 8'hf0;

	if((mode_reg & 8'h30) != 8'h20)			  
	   input_byte(cmd_byte);	           
		   
	if(!is_qpi(cmd_byte) && !CSn)
	begin
		$display("WARNING: Non-QPI command was executed in QPI mode");
        $stop;
	end
	
	if(cmd_byte != `CMD_CHIP_RESET && !CSn)
	   flag_enable_reset = 0;   

    if (!CSn) begin
	case (cmd_byte)				         
   `CMD_SET_READ_PARAM :
    begin
      if(!status_reg[`WIP] && !flag_power_down && flag_qpi_mode)
      begin
 		   	input_byte(read_param_reg_shadow);
            if (!CSn) begin
     			flag_set_read_param = 1;
     			get_posclk_holdn;
     			flag_set_read_param = 0;
            end
 		  end
    end  

    `CMD_ENABLE_QPI :
    begin
      if(!status_reg[`WIP] && !flag_power_down)
      begin
         if(status_reg[`QE] == 1)
             flag_qpi_mode = 1;
      end
    end  

    `CMD_MODE_RESET :
	  begin
	    if(!flag_power_down)   
 		       flag_qpi_mode = 0;
	  end
	
	  `CMD_ENABLE_RESET :            
	  begin
       flag_enable_reset = 1;		    
	  end
	    
		`CMD_CHIP_RESET :
		begin
		   if(flag_enable_reset == 1)
		   begin
    		  flag_reset = 1;
   			  @(posedge CLK or posedge CSn);
			  flag_reset = 0;
           end
        end

		`CMD_DEEP_POWERDOWN :
		begin
      if(!status_reg[`WIP] && !flag_power_down)
      begin
		     flag_power_down = 1;
  			 @(posedge CLK or posedge CSn);
		     flag_power_down = 0;
			end
		end
		
		`CMD_READ_SIGNATURE :
		begin
         if(!status_reg[`WIP])
         begin
           		flag_power_up_exec = 1;
           		input_byte(null_reg);
           		input_byte(null_reg);
           		input_byte(null_reg);
            	while(!CSn)
           		begin
           		   output_byte(DEVICE_ID);
          		   flag_power_up_sig_read = 1;
           		end
         end
		end

		`CMD_READ_JEDEC_ID :
		begin
         if(!status_reg[`WIP] && !flag_power_down)
         begin
            output_byte(MANUFACTURER);
            if(flag_qpi_mode)
                output_byte(JEDEC_ID_HI_QPI);
            else
                output_byte(JEDEC_ID_HI);
            output_byte(JEDEC_ID_LO);
         end
		end

		`CMD_READ_ID :
		begin
         if(!status_reg[`WIP] && !flag_power_down)
         begin
            byte_address = 0;               
            input_byte(byte_address[23:16]);
            input_byte(byte_address[15:8]);
            input_byte(byte_address[7:0]);
            while(!CSn)
            begin
               if(byte_address[0])
	            begin
	               output_byte(DEVICE_ID);
                   output_byte(MANUFACTURER);
                end
                else
                begin
                   output_byte(MANUFACTURER);
                   output_byte(DEVICE_ID);
                end
            end				    
         end
      end

     `CMD_READ_ID_DUAL :  
	   begin
         if(!status_reg[`WIP] && !flag_power_down)
         begin
            byte_address = 0;                          
            input_byte_dual(byte_address[23:16]);
            input_byte_dual(byte_address[15:8]);
            input_byte_dual(byte_address[7:0]);
            input_byte_dual(mode_reg[7:0]);
            while(!CSn)
            begin
               if(byte_address[0])
	            begin
	               output_byte_dual(DEVICE_ID);
                   output_byte_dual(MANUFACTURER);
               end
               else
               begin
                  output_byte_dual(MANUFACTURER);
                  output_byte_dual(DEVICE_ID);
               end
            end				    
         end
      end

      `CMD_READ_ID_QUAD :
      begin
         if(!status_reg[`WIP] && !flag_power_down && status_reg[`QE])
         begin  
            byte_address = 0;                       
            input_byte_quad(byte_address[23:16]);
            input_byte_quad(byte_address[15:8]);
            input_byte_quad(byte_address[7:0]);
            input_byte_quad(mode_reg[7:0]);                
            input_byte_quad(temp[7:0]);
            input_byte_quad(temp[7:0]);
            while(!CSn)
            begin
               if(byte_address[0])
	            begin
	               output_byte_quad(DEVICE_ID);
                   output_byte_quad(MANUFACTURER);
               end
               else
               begin
                  output_byte_quad(MANUFACTURER);
                  output_byte_quad(DEVICE_ID);
               end
            end				    
         end
      end
    
   	`CMD_READ_UNIQUE_ID :
		begin
			if(!status_reg[`WIP] && !flag_power_down)
			begin
				input_byte(null_reg);
				input_byte(null_reg);
				input_byte(null_reg);
				input_byte(null_reg);
				output_byte(UNIQUE_ID[63:56]);
				output_byte(UNIQUE_ID[55:48]);
				output_byte(UNIQUE_ID[47:40]);
				output_byte(UNIQUE_ID[39:32]);	
				output_byte(UNIQUE_ID[31:24]);
				output_byte(UNIQUE_ID[23:16]);
				output_byte(UNIQUE_ID[15:8]);
				output_byte(UNIQUE_ID[7:0]);
			end
		end

		`CMD_WRITE_ENABLE :
		begin
			if((!flag_power_down)	&& (WPn || status_reg[`QE]))
				status_reg[`WEL] = 1;
	   end
	   
	   `CMD_WRITE_ENABLE_VSR :
	   begin
			if(!flag_power_down)	
			   flag_volatile_sr_write = 1;
	   end
	   
	   `CMD_WRITE_DISABLE :
	   begin
	      if(!flag_power_down)
				status_reg[`WEL] = 0;
	   end

		`CMD_READ_STATUS :
		begin
			 if(!flag_power_down)
			 begin
				 while(!CSn)
				 begin
					  output_byte(status_reg[7:0]);
				 end
			 end
		end

		`CMD_READ_STATUS2 :
		begin
			if(!flag_power_down)
			begin
				while(!CSn)
				begin
					output_byte(status_reg[15:8]);
				end
			end
		end

		`CMD_READ_STATUS3 :
		begin
			if(!flag_power_down)
			begin
				while(!CSn)
				begin
					output_byte(status_reg[23:16]);
				end
			end
		end


		`CMD_WRITE_STATUS :
		begin
	     	if(!status_reg[`WIP] && (status_reg[`WEL] || flag_volatile_sr_write) && !flag_power_down && !status_reg[`SUS])
            begin
                flag_read_op_reg = 1'b0;
  		        case ({status_reg[`SRP1],status_reg[`SRP0]})
                2'b00, 2'b01 :
       			begin
  		  	      if((status_reg[`SRP0] && WPn) || !status_reg[`SRP0] || status_reg[`QE]) 
         			begin
           				status_reg_shadow[23:8] = status_reg[23:8];
          			 	input_byte(status_reg_shadow[7:0]);
  		         		
                        if (!CSn) begin
                            flag_write_status_reg = 1;
           				    if(flag_qpi_mode == 1) @(posedge CLK or posedge CSn);
  						    else get_posclk_holdn;  						
                            flag_write_status_reg = 0;
                        end

                        if (!CSn) begin
  						    input_byte_no1stclock(temp);
                            if (!CSn) begin
           					    flag_write_status_reg = 1;
           					    status_reg_shadow[15:8] = temp;
           					    if(flag_qpi_mode == 1) @(posedge CLK or posedge CSn);
           					    else get_posclk_holdn; 						
                                flag_write_status_reg = 0;
                            end
                        end
         			end
    		  	end
  				endcase
 		    end
		end
		
		`CMD_WRITE_STATUS2 :
		begin
	     	if(!status_reg[`WIP] && (status_reg[`WEL] || flag_volatile_sr_write) && !flag_power_down && !status_reg[`SUS])
        begin
            flag_read_op_reg = 1'b0;
				    case ({status_reg[`SRP1],status_reg[`SRP0]})
					  2'b00, 2'b01 :
					  begin
						   if((status_reg[`SRP0] && WPn) || !status_reg[`SRP0] || status_reg[`QE]) 
						   begin
							    status_reg_shadow[23:16] = status_reg[23:16];
							    status_reg_shadow[7:0] = status_reg[7:0];							    
			 				    input_byte(status_reg_shadow[15:8]);
							    if (!CSn) begin
                                    flag_write_status_reg = 1;
							        if(flag_qpi_mode == 1) @(posedge CLK or posedge CSn);
							        else get_posclk_holdn;  							
                                    flag_write_status_reg = 0;
                                end
						   end
 					 end
				   endcase
		   end
		end

		`CMD_WRITE_STATUS3 :
		begin
	     	if(!status_reg[`WIP] && (status_reg[`WEL] || flag_volatile_sr_write) && !flag_power_down && !status_reg[`SUS])
        begin
            flag_read_op_reg = 1'b0;
				    case ({status_reg[`SRP1],status_reg[`SRP0]})
					  2'b00, 2'b01 :
					  begin
						   if((status_reg[`SRP0] && WPn) || !status_reg[`SRP0] || status_reg[`QE]) 
						   begin
							    status_reg_shadow[15:0] = status_reg[15:0];
			 				    input_byte(status_reg_shadow[23:16]);
							    if (!CSn) begin
                                    flag_write_status_reg = 1;
							        if(flag_qpi_mode == 1) @(posedge CLK or posedge CSn);
							        else get_posclk_holdn; 						
                                    flag_write_status_reg = 0;
                                end
						   end
 					 end
				   endcase
		   end
		end

		`CMD_PAGE_PROGRAM :
		begin
			if(status_reg[`WEL] && !status_reg[`SUS] && !flag_power_down)
			begin
			   flag_read_op_reg = 1'b0;
				 write_page(0);
			end
		end

		`CMD_PAGE_PROGRAM_QUAD :
		begin
			if(status_reg[`WEL]&& !status_reg[`SUS] && status_reg[`QE] && !flag_power_down)
			begin
			   flag_read_op_reg = 1'b0;
	    		write_page(1);
			end
		end

      `CMD_SUSPEND :
      begin
         if(!flag_power_down && !flag_erase_bulk)
         begin
            if((!flag_suspend) && (flag_erase_sector || flag_erase_secsi_sector || flag_erase_half_block || flag_erase_block || flag_prog_page || flag_prog_secsi_page))
            begin
                flag_suspend = 1'b1;
                get_posclk_holdn;   
                flag_suspend = 1'b0;
            end
         end
      end
      
      `CMD_RESUME :
      begin
          if(!flag_power_down)
          begin
             if(flag_suspend)
             begin
                 flag_resume = 1'b1;
                 get_posclk_holdn;   
                 flag_resume = 1'b0;
             end
          end
      end
      
		`CMD_SECTOR_ERASE :
		begin
			if(status_reg[`WEL] && !flag_power_down && !status_reg[`SUS])
			begin
   		        flag_read_op_reg = 1'b0;
				input_byte(byte_address[23:16]);
				input_byte(byte_address[15:8]);
				input_byte(byte_address[7:0]);
				byte_address = byte_address & ADDRESS_MASK;
				if(!write_protected(byte_address) && !CSn)
				begin
					flag_erase_sector = 1;
					get_posclk_holdn;				
					flag_erase_sector = 0;
				end
			end
		end

		`CMD_HALF_BLOCK_ERASE :
		begin
			if(status_reg[`WEL] && !flag_power_down && !status_reg[`SUS])
			begin
   		        flag_read_op_reg = 1'b0;
				input_byte(byte_address[23:16]);
				input_byte(byte_address[15:8]);
				input_byte(byte_address[7:0]);
				byte_address = byte_address & ADDRESS_MASK;
				if(!write_protected(byte_address) && !CSn)
				begin
					flag_erase_half_block = 1;
					get_posclk_holdn;				
					flag_erase_half_block = 0;
				end
			end
		end

		`CMD_BLOCK_ERASE :
		begin
			if(status_reg[`WEL] && !flag_power_down && !status_reg[`SUS])
			begin
   		        flag_read_op_reg = 1'b0;
				input_byte(byte_address[23:16]);
				input_byte(byte_address[15:8]);
				input_byte(byte_address[7:0]);
				byte_address = byte_address & ADDRESS_MASK;
				if(!write_protected(byte_address) && !CSn)
				begin
					flag_erase_block = 1;
					get_posclk_holdn;				
					flag_erase_block = 0;
				end
			end
		end

		`CMD_BULK_ERASE, `CMD_BULK_ERASE2 :
		begin
			if(status_reg[`WEL] && !flag_power_down && !status_reg[`SUS])
			begin
			   flag_read_op_reg = 1'b0;
				case ({status_reg[`BP0],status_reg[`BP1]})
					2'b00 :
					begin
                        if (!CSn) begin
						    flag_erase_bulk = 1;
						    get_posclk_holdn;
						    flag_erase_bulk = 0;
                        end
					end
				endcase
			end
		end

		`CMD_READ_DATA :
		begin
			if(!flag_power_down)
			begin
				flag_slow_read_reg = 1'b1;
				read_page(0,0);
			end
		end
		
		`CMD_READ_DATA_FAST :
		begin
			if(!flag_power_down)
				read_page(1,0);
		end
		
		`CMD_READ_DATA_FAST_WRAP :
		begin
      	   if(!flag_power_down)
      	   begin  
      	     if(flag_qpi_mode) read_page_quadio(cmd_byte);     	       
             else              read_page(1,0);
          end 
		end
		    
		`CMD_READ_DATA_FAST_DUAL :
		begin
			if(!flag_power_down) read_page(2,0);
		end
		
		`CMD_READ_DATA_FAST_QUAD :
		begin
			if(!flag_power_down && status_reg[`QE]) read_page(3,0);
		end
		
		`CMD_READ_DATA_FAST_DUAL_IO :
		begin
			if(!flag_power_down) read_page_dualio;
		end
		
		`CMD_READ_DATA_FAST_QUAD_IO :
		begin
			if(!flag_power_down && status_reg[`QE]) read_page_quadio(cmd_byte);
		end

		`CMD_READ_OCTAL_FAST_QUAD_IO :
		begin
			if(!flag_power_down && status_reg[`QE]) read_page_quadio(cmd_byte);
		end
		
		`CMD_READ_WORD_FAST_QUAD_IO :
		begin
		    if(!flag_power_down && status_reg[`QE]) read_page_quadio(cmd_byte);
		end
		
		`CMD_SET_BURST_WRAP :
		begin
    		if(!flag_power_down && status_reg[`QE])
    		begin
      	       input_byte_quad(temp[7:0]);	
   	    	   input_byte_quad(temp[7:0]);	
   	    	   input_byte_quad(temp[7:0]);	   	    	      	    	   
   	    	   input_byte_quad(wrap_reg[7:0]);	   	    	      	    	   
			end
		end
		
		`CMD_READ_SFDP :
		begin
			if(!flag_power_down)
			begin
				flag_slow_read_reg = 1'b1;
				read_page(0,2);
			end
		end

      `CMD_SREG_READ :
      begin
      		if(!flag_power_down) read_page(0,1);
	  end
      
      `CMD_SREG_ERASE :
      begin
			if(status_reg[`WEL] && !flag_power_down && !status_reg[`SUS])
			begin
			     flag_read_op_reg = 1'b0;
				 input_byte(byte_address[23:16]);
				 input_byte(byte_address[15:8]);
				 input_byte(byte_address[7:0]);
                 if (!CSn) begin
				    case (byte_address[23:8])
					16'h10 :
					begin
					   if(!status_reg[`LB1]) begin
      						flag_erase_secsi_sector = 1; get_posclk_holdn; flag_erase_secsi_sector = 0;
						end
					end
					16'h20 :
					begin
					   if(!status_reg[`LB2]) begin
      						flag_erase_secsi_sector = 1; get_posclk_holdn; flag_erase_secsi_sector = 0;
						end
					end
					16'h30 :
					begin
					   if(!status_reg[`LB3]) begin
      						flag_erase_secsi_sector = 1; get_posclk_holdn; flag_erase_secsi_sector = 0;
						end
					end
				    endcase
                 end
			end
      end
      
    `CMD_SREG_PROGRAM :
		begin
			if(status_reg[`WEL] && !flag_power_down && !status_reg[`SUS])
			begin
			   flag_read_op_reg = 1'b0;
               if(!status_reg[`WIP])
               begin
            		  input_byte(prog_byte_address[23:16]);
		              input_byte(prog_byte_address[15:8]);
		              input_byte(prog_byte_address[7:0]);
                      if (!CSn) begin
   				          case (byte_address[23:8])
					         16'h10 : if(!status_reg[`LB1]) fill_page_latch(0,prog_byte_address,1);
  				             16'h20 : if(!status_reg[`LB2]) fill_page_latch(0,prog_byte_address,1);
					         16'h30 : if(!status_reg[`LB3]) fill_page_latch(0,prog_byte_address,1);
				          endcase
                      end
		        end
            end
		end
    
    `CMD_GLOBAL_BLOCK_LOCK :
    begin
      if(!status_reg[`WIP] && !flag_power_down)
      begin
        for(x = 0; x < NUM_LOCKBITS; x=x+1) lock_array[x] = 1;
      end
    end
    
    `CMD_GLOBAL_BLOCK_UNLOCK :
    begin
      if(!status_reg[`WIP] && !flag_power_down)
      begin
        for(x = 0; x < NUM_LOCKBITS; x=x+1) lock_array[x] = 0;
      end
    end
    
    `CMD_INDIVIDUAL_LOCK :
    begin
      if(!status_reg[`WIP] && !flag_power_down)
      begin
   		 input_byte(byte_address[23:16]);
         input_byte(byte_address[15:8]);
         input_byte(byte_address[7:0]);
         if (!CSn) lock_array[lockbit_index(byte_address)] = 1;
      end
    end
    
    `CMD_INDIVIDUAL_UNLOCK :
    begin
      if(!status_reg[`WIP] && !flag_power_down)
      begin
   		 input_byte(byte_address[23:16]);
         input_byte(byte_address[15:8]);
         input_byte(byte_address[7:0]);
         if (!CSn) lock_array[lockbit_index(byte_address)] = 0;
      end
    end
    
    `CMD_READ_BLOCK_LOCK :
    begin
      if(!status_reg[`WIP] && !flag_power_down)
      begin
   		 input_byte(byte_address[23:16]);
         input_byte(byte_address[15:8]);
         input_byte(byte_address[7:0]);
         if (!CSn) begin
             null_reg[7:1] = 0;
             null_reg[0] = lock_array[lockbit_index(byte_address)];
             output_byte(null_reg);
         end
      end
    end
          		
		default :
		begin
			$display("Invalid Opcode. (%0h)",cmd_byte);
			$stop;
		end
	endcase
    end
end


/******************************************************************************
 The following routine occurs when CSn goes high. 
 CRITICAL VERILATOR FIX: NO TASK DISABLES ARE USED HERE.
******************************************************************************/
always @(posedge CSn)		   		      
begin :disable_interface
	#tSHQZ;						                  
	HOLDn_Active = 1'b0;           
	DO_Output_Enable = 1'b0;			    					
	DIO_Output_Enable_reg = 1'b0;		
	WPn_Output_Enable_reg = 1'b0;		
	HOLDn_Output_Enable = 1'b0;		  
	flag_slow_read_reg = 1'b0;			  
end

/******************************************************************************
 HOLDn Logic
******************************************************************************/
always @(negedge (HOLDn & !status_reg[`QE] & !CSn))		   		      
begin
   if(!HOLDn)
   begin
      #12;
      temp_DIO_Output_Enable_reg = DIO_Output_Enable_reg;
      temp_DO_Output_Enable = DO_Output_Enable;
      DIO_Output_Enable_reg = 1'b0;               
      DO_Output_Enable = 1'b0;
      HOLDn_Active = 1'b1;
   end
end
   
always @(posedge HOLDn)		   		      
begin
   if(HOLDn_Active == 1'b1)
   begin
       #7;
       DIO_Output_Enable_reg = temp_DIO_Output_Enable_reg;
       DO_Output_Enable = temp_DO_Output_Enable;	
       HOLDn_Active = 1'b0;
   end
end

/******************************************************************************
 GENERAL PURPOSE SUBROUTINES
******************************************************************************/
task chip_reset;
integer x;
begin
	temp_DIO_Output_Enable_reg = 1'b0;
	DIO_Output_Enable_reg = 1'b0;				
	temp_DO_Output_Enable = 1'b0;
	DO_Output_Enable = 1'b0;	   				 
	WPn_Output_Enable_reg = 1'b0;				
	HOLDn_Output_Enable = 1'b0;				  
	HOLDn_Active = 1'b0;

	DIO_Reg = 1'b0; DO_Reg = 1'b0; WPn_Reg = 1'b0; HOLDn_Reg = 1'b0;
	
	mode_reg = 8'h00;					        
	wrap_reg = 8'b00010000;       
	read_param_reg = 8'h00;       
   
	status_reg = 0;             		
    status_reg[`QE] = status_reg_otp[`QE];
    status_reg[`SRP1] = status_reg_otp[`SRP1];
    status_reg[`SRP0] = status_reg_otp[`SRP0];
    status_reg[`BP0] = status_reg_otp[`BP0];
    status_reg[`BP1] = status_reg_otp[`BP1];
    status_reg[`BP2] = status_reg_otp[`BP2];
    status_reg[`TB] = status_reg_otp[`TB];
    status_reg[`SEC] = status_reg_otp[`SEC];
    status_reg[`CMP] = status_reg_otp[`CMP];
    status_reg[`WPS] = status_reg_otp[`WPS];
    status_reg[`DRV0] = status_reg_otp[`DRV0];
    status_reg[`DRV1] =  status_reg_otp[`DRV1];
    status_reg[`HLD_RST] = status_reg_otp[`HLD_RST];
    status_reg[`LB1] = status_reg_otp[`LB1];
    status_reg[`LB2] = status_reg_otp[`LB2];
    status_reg[`LB3] = status_reg_otp[`LB3];	
	
	flag_prog_page = 0; flag_prog_secsi_page = 0; flag_erase_sector = 0;
	flag_erase_half_block = 0; flag_erase_block = 0; flag_erase_secsi_sector = 0;
	flag_erase_bulk = 0; flag_power_down = 0; flag_power_up_exec = 0;
	flag_power_up_sig_read = 0; flag_write_status_reg = 0; flag_slow_read_reg = 1'b0;				
	flag_read_op_reg = 1'b0; flag_suspend = 1'b0; flag_suspend_enabled = 1'b0;
	flag_volatile_sr_write = 1'b0; flag_qpi_mode = 0; flag_enable_reset = 0;
	flag_reset = 0; flag_reset_condition = 0; flag_set_read_param = 0;
	timing_error = 0; cmd_byte = 0; null_reg = 0; in_byte = 0; out_byte = 0;
	
	for(x = 0; x < NUM_LOCKBITS; x=x+1) lock_array[x] = 1;
end
endtask

// -------------------------------------------------------------
// VERILATOR FIX: All input/output loops check `!CSn` dynamically
// -------------------------------------------------------------

task input_byte;
output [7:0] input_data;
integer x;
begin
   if(flag_qpi_mode == 1) input_byte_quad(input_data);
   else begin	
	   if(DIO_Output_Enable_reg != 1'b0) DIO_Output_Enable_reg = 1'b0;
	   for(x = 7; x >= 0 && !CSn; x=x-1) begin
	      get_posclk_holdn;
          if (!CSn) input_data[x] = DIO;
       end
	   if (!CSn) in_byte = input_data;
	end
end
endtask

task input_byte_no1stclock;
output [7:0] input_data;
integer x;
begin
   if(flag_qpi_mode == 1) input_byte_quad_no1stclock(input_data);
   else begin	
	   if(DIO_Output_Enable_reg != 1'b0) DIO_Output_Enable_reg = 1'b0;
	   for(x = 7; x >= 0 && !CSn; x=x-1) begin
	      if(x != 7) get_posclk_holdn;
          if (!CSn) input_data[x] = DIO;
       end
	   if (!CSn) in_byte = input_data;
   end
end
endtask

task input_byte_dual;
output [7:0] input_data;
integer x;
begin
	if(DIO_Output_Enable_reg != 1'b0) DIO_Output_Enable_reg = 1'b0;
	if(DO_Output_Enable != 1'b0) DO_Output_Enable = 1'b0;
	for(x = 7; x >= 0 && !CSn; x=x-2) begin
	    get_posclk_holdn;
        if (!CSn) begin
	        input_data[x-1] = DIO;		
		    input_data[x] = DO;   
        end
    end
	if (!CSn) in_byte = input_data;
end
endtask

task input_mode_dual;
output [5:0] input_data;
integer x;
begin
	if(DIO_Output_Enable_reg != 1'b0) DIO_Output_Enable_reg = 1'b0;
	if(DO_Output_Enable != 1'b0) DO_Output_Enable = 1'b0;
	for(x = 5; x >= 0 && !CSn; x=x-2) begin
	    get_posclk_holdn;
        if (!CSn) begin
	        input_data[x-1] = DIO;		
		    input_data[x] = DO;   
        end
    end
end
endtask

task input_byte_quad;
output [7:0] input_data;
integer x;
begin
	if(DIO_Output_Enable_reg != 1'b0) DIO_Output_Enable_reg = 1'b0;
	if(DO_Output_Enable != 1'b0) DO_Output_Enable = 1'b0;
	if(WPn_Output_Enable_reg != 1'b0) WPn_Output_Enable_reg = 1'b0;
	if(HOLDn_Output_Enable != 1'b0) DO_Output_Enable = 1'b0;

	for(x = 7; x >= 0 && !CSn; x=x-4) begin
	    @(posedge CLK or posedge CSn);
        if (!CSn) begin
		    input_data[x-3] = DIO;
            input_data[x-2] = DO;
		    input_data[x-1] = WPn;
		    input_data[x] = HOLDn;
        end
    end
	if (!CSn) in_byte = input_data;
end
endtask

task input_byte_quad_no1stclock;
output [7:0] input_data;
integer x;
begin
	if(DIO_Output_Enable_reg != 1'b0) DIO_Output_Enable_reg = 1'b0;
	if(DO_Output_Enable != 1'b0) DO_Output_Enable = 1'b0;
	if(WPn_Output_Enable_reg != 1'b0) WPn_Output_Enable_reg = 1'b0;
	if(HOLDn_Output_Enable != 1'b0) DO_Output_Enable = 1'b0;

	for(x = 7; x >= 0 && !CSn; x=x-4) begin
	    if(x != 7) @(posedge CLK or posedge CSn);
        if (!CSn) begin
	  	    input_data[x-3] = DIO;
            input_data[x-2] = DO;
		    input_data[x-1] = WPn;
		    input_data[x] = HOLDn;
        end
    end
	if (!CSn) in_byte = input_data;
end
endtask

task output_byte;
input [7:0] output_data;
integer x;
begin
   if(flag_qpi_mode == 1) output_byte_quad(output_data);
   else begin
      if (!CSn) out_byte = output_data;
	   for(x = 7; x >= 0 && !CSn; x=x-1) begin
	      get_negclk_holdn;
          if (!CSn) begin
		      if(DO_Output_Enable == 1'b0) DO_Output_Enable = 1'b1;
              #tCLQV DO_Reg = output_data[x];
          end
	   end
   end
end
endtask

task output_byte_dual;
input [7:0] output_data;
integer x;
begin
	if (!CSn) out_byte = output_data;
	for(x = 7; x >= 0 && !CSn; x=x-2) begin
	    get_negclk_holdn;
        if (!CSn) begin
		    if(DO_Output_Enable == 1'b0) DO_Output_Enable = 1'b1;
		    if(DIO_Output_Enable_reg == 1'b0) DIO_Output_Enable_reg = 1'b1;
		    #tCLQV ;
		    DIO_Reg = output_data[x-1];
     	    DO_Reg = output_data[x];
        end
	end
end
endtask

task output_byte_quad;
input [7:0] output_data;
integer x;
begin
	if (!CSn) out_byte = output_data;
	for(x = 7; x >= 0 && !CSn; x=x-4) begin
		@(negedge CLK or posedge CSn);
        if (!CSn) begin
		    if(DO_Output_Enable == 1'b0) DO_Output_Enable = 1'b1;
		    if(DIO_Output_Enable_reg == 1'b0) DIO_Output_Enable_reg = 1'b1;
		    if(WPn_Output_Enable_reg == 1'b0) WPn_Output_Enable_reg = 1'b1;
		    if(HOLDn_Output_Enable == 1'b0) HOLDn_Output_Enable = 1'b1;
		    #tCLQV;
		    DIO_Reg = output_data[x-3];
		    DO_Reg = output_data[x-2];
   	        WPn_Reg = output_data[x-1];
   	        HOLDn_Reg = output_data[x];
        end
	end
end
endtask

// -------------------------------------------------------------
// VERILATOR FIX: Clocks unblock correctly on CSn assertions
// -------------------------------------------------------------

task get_negclk_holdn;
begin
   if(status_reg[`QE]) @(negedge CLK or posedge CSn);               
   else @(negedge (CLK & HOLDn) or posedge CSn);     
end
endtask

task get_posclk_holdn;
begin
   if(status_reg[`QE]) @(posedge CLK or posedge CSn);               
   else @(posedge (CLK & HOLDn) or posedge CSn);     
end
endtask

task wait_reset_suspend;
input [31:0] delay;
integer waitx;
integer num_iterations;
begin
      waitx = 0;
      if(delay >= 1000) begin
        num_iterations = delay / 1000;
      	for(waitx = 0; waitx < num_iterations; waitx=waitx+1) begin
	   		if(flag_reset_condition) waitx = num_iterations;                           
            else begin
		  		wait(!flag_suspend_enabled || flag_reset_condition);
	   			#1000;
	   		end
		end
	  end
      num_iterations = delay % 1000;
      for(waitx = 0; waitx < num_iterations; waitx=waitx+1) begin
    	if(flag_reset_condition) waitx = num_iterations;
	    else begin 
		    wait(!flag_suspend_enabled || flag_reset_condition);   
            #1;
		end
  	  end
end
endtask

task wait_reset;
input [31:0] delay;
integer waitx;
integer num_iterations;
begin
      waitx = 0;
      if(delay >= 1000) begin
        num_iterations = delay / 1000;
      	for(waitx = 0; waitx < num_iterations; waitx=waitx+1) begin
	   		if(flag_reset_condition) waitx = num_iterations;                           
            else #1000;                              
   	  	end
	  end
      num_iterations = delay % 1000;
      for(waitx = 0; waitx < num_iterations; waitx=waitx+1) begin
    	if(flag_reset_condition) waitx = num_iterations;
	    else #1;
  	  end
end
endtask

function write_protected;
input [23:0] byte_address;
begin
  if(status_reg[`WPS]) write_protected = lock_array[lockbit_index(byte_address)];
  else begin
    	casez ({status_reg[`SEC], status_reg[`TB],status_reg[`BP2],status_reg[`BP1],status_reg[`BP0]})
    		5'b??000 : write_protected = 1'b0 ^ status_reg[`CMP];
    		5'b00001 : begin
    			  if(byte_address >= (NUM_PAGES * 31 / 32 * PAGESIZE)) write_protected = 1'b1 ^ status_reg[`CMP];
    			  else write_protected = 1'b0 ^ status_reg[`CMP];
    		end		
    		5'b00010 : begin
    			  if(byte_address >= (NUM_PAGES * 15 / 16 * PAGESIZE)) write_protected = 1'b1 ^ status_reg[`CMP];
    			  else write_protected = 1'b0 ^ status_reg[`CMP];
    		end
    		5'b00011 : begin
    			  if(byte_address >= (NUM_PAGES * 7 / 8 * PAGESIZE)) write_protected = 1'b1 ^ status_reg[`CMP];
    			  else write_protected = 1'b0 ^ status_reg[`CMP];
    		end
    		5'b00100 : begin
    			  if(byte_address >= (NUM_PAGES * 3 / 4 * PAGESIZE)) write_protected = 1'b1 ^ status_reg[`CMP];
    			  else write_protected = 1'b0 ^ status_reg[`CMP];
    		end
    		5'b00101 : begin
    			  if(byte_address >= (NUM_PAGES * 1 / 2 * PAGESIZE)) write_protected = 1'b1 ^ status_reg[`CMP];
    			  else write_protected = 1'b0 ^ status_reg[`CMP];
    		end
    		5'b01001 : begin
    			  if(byte_address < (NUM_PAGES * 1 / 32 * PAGESIZE)) write_protected = 1'b1 ^ status_reg[`CMP];
    			  else write_protected = 1'b0 ^ status_reg[`CMP];
    		end
    		5'b01010 : begin
    			  if(byte_address < (NUM_PAGES * 1 / 16 * PAGESIZE)) write_protected = 1'b1 ^ status_reg[`CMP];
    			  else write_protected = 1'b0 ^ status_reg[`CMP];
    		end
    		5'b01011 : begin
    			  if(byte_address < (NUM_PAGES * 1 / 8 * PAGESIZE)) write_protected = 1'b1 ^ status_reg[`CMP];
    			  else write_protected = 1'b0 ^ status_reg[`CMP];
    		end
    		5'b01100 : begin
    			  if(byte_address < (NUM_PAGES * 1 / 4 * PAGESIZE)) write_protected = 1'b1 ^ status_reg[`CMP];
    			  else write_protected = 1'b0 ^ status_reg[`CMP];
    		end
    		5'b01101 : begin
    			  if(byte_address < (NUM_PAGES * 1 / 2 * PAGESIZE)) write_protected = 1'b1 ^ status_reg[`CMP];
    			  else write_protected = 1'b0 ^ status_reg[`CMP];
    		end
 		    5'b??11? : write_protected = 1'b1 ^ status_reg[`CMP];
    		5'b10001 : begin
    			  if(byte_address >= (NUM_PAGES * 511 / 512 * PAGESIZE)) write_protected = 1'b1 ^ status_reg[`CMP];
  			      else write_protected = 1'b0 ^ status_reg[`CMP];
    		end
    		5'b10010 : begin
    			  if(byte_address >= (NUM_PAGES * 255 / 256 * PAGESIZE)) write_protected = 1'b1 ^ status_reg[`CMP];
    			  else write_protected = 1'b0 ^ status_reg[`CMP];
    		end
    		5'b10011: begin
    			  if(byte_address >= (NUM_PAGES * 127 / 128 * PAGESIZE)) write_protected = 1'b1 ^ status_reg[`CMP];
    			  else write_protected = 1'b0 ^ status_reg[`CMP];
    		end
    		5'b1010? : begin
    			  if(byte_address >= (NUM_PAGES * 63 / 64 * PAGESIZE)) write_protected = 1'b1 ^ status_reg[`CMP];
    			  else write_protected = 1'b0 ^ status_reg[`CMP];
    		end
    		5'b11001 : begin
    			  if(byte_address < (NUM_PAGES * 1 / 512 * PAGESIZE)) write_protected = 1'b1 ^ status_reg[`CMP];
  			      else write_protected = 1'b0 ^ status_reg[`CMP];
    		end
    		5'b11010 : begin
    			  if(byte_address < (NUM_PAGES * 1 / 256 * PAGESIZE)) write_protected = 1'b1 ^ status_reg[`CMP];
    			  else write_protected = 1'b0 ^ status_reg[`CMP];
    		end
    		5'b11011: begin
    			  if(byte_address < (NUM_PAGES * 1 / 128 * PAGESIZE)) write_protected = 1'b1 ^ status_reg[`CMP];
    			  else write_protected = 1'b0 ^ status_reg[`CMP];
    		end
    		5'b1110? : begin
    			  if(byte_address < (NUM_PAGES * 1 / 64 * PAGESIZE)) write_protected = 1'b1 ^ status_reg[`CMP];
    			  else write_protected = 1'b0 ^ status_reg[`CMP];
    		end
    	endcase
	end
end
endfunction

function is_qpi;
input [7:0] cmd_byte;
begin
   if(flag_qpi_mode == 1) begin
     	case (cmd_byte)				         
      `CMD_WRITE_ENABLE, `CMD_WRITE_ENABLE_VSR, `CMD_WRITE_DISABLE, `CMD_READ_STATUS,
      `CMD_READ_STATUS2, `CMD_READ_STATUS3, `CMD_WRITE_STATUS, `CMD_WRITE_STATUS2, `CMD_WRITE_STATUS3, `CMD_PAGE_PROGRAM, 
      `CMD_INDIVIDUAL_LOCK, `CMD_INDIVIDUAL_UNLOCK, `CMD_READ_BLOCK_LOCK, `CMD_GLOBAL_BLOCK_LOCK, `CMD_GLOBAL_BLOCK_UNLOCK,
      `CMD_SECTOR_ERASE,`CMD_HALF_BLOCK_ERASE, `CMD_BLOCK_ERASE, `CMD_BULK_ERASE, `CMD_BULK_ERASE2,
      `CMD_SUSPEND, `CMD_RESUME, `CMD_DEEP_POWERDOWN, `CMD_SET_READ_PARAM, `CMD_READ_DATA_FAST,
      `CMD_READ_DATA_FAST_WRAP, `CMD_READ_DATA_FAST_QUAD_IO, `CMD_READ_SIGNATURE, `CMD_READ_ID, `CMD_READ_JEDEC_ID,
      `CMD_READ_UNIQUE_ID, `CMD_DISABLE_QPI, `CMD_ENABLE_RESET, `CMD_CHIP_RESET  :
       begin
         is_qpi = 1;
       end
       default : begin
		   is_qpi = 0;
		   $display("Invalid Opcode for QPI mode. (%0h)",cmd_byte);
	    end
	    endcase 
   end else is_qpi = 1;
end
endfunction

function integer lockbit_index;
input [23:0] byte_address;
begin
   if((byte_address[23:16] == 0) || (byte_address[23:16] == (NUM_BLOCKS-1))) begin
      if(byte_address[23:16] == 0) lockbit_index = byte_address[15:0] / SECTORSIZE;
      else lockbit_index = (byte_address[15:0] / SECTORSIZE) + 16;
   end else lockbit_index = byte_address[23:16] - 1 + 32;
end
endfunction   
        
// -------------------------------------------------------------
// VERILATOR FIX: Replaced all `forever` loops with `while(!CSn)`
// -------------------------------------------------------------

task read_page;
input [1:0] fast_read;                         
input [1:0] mem_read;                          
integer x;
begin
	if(!status_reg[`WIP]) begin
		input_byte(byte_address[23:16]);	
		input_byte(byte_address[15:8]);
		input_byte(byte_address[7:0]);
		if(fast_read) begin
		   if(flag_qpi_mode == 1) begin
		       for(x = 0; x <= read_param_reg[5:4] && !CSn; x = x + 1) input_byte(null_reg);
		   end else input_byte(null_reg);
   	    end
   	
   	    if(mem_read) input_byte(null_reg);
   	  
		while(!CSn) begin
		   if(mem_read == 1) begin 
             case(byte_address[23:8])
               16'h10 : output_byte(secsi[byte_address[7:0]]);             
               16'h20 : output_byte(secsi[byte_address[7:0]+PAGESIZE]);                       
               16'h30 : output_byte(secsi[byte_address[7:0]+(2*PAGESIZE)]);                       
               default : begin
                 $display("Invalid Security Page Address (%x)",byte_address);
                 $stop;
               end
             endcase  
           end else if(mem_read == 2) begin 
		     if(byte_address[23:8] == 0) output_byte(sfdp[byte_address[7:0]]);
		     else begin
		        $display("Invalid SFDP Page Address (%x)", byte_address);
		        $stop;
             end		     
	       end else begin    
		      byte_address = byte_address & ADDRESS_MASK;
		      if(fast_read == 2) output_byte_dual(memory[byte_address]);
      		  else if(fast_read == 3) output_byte_quad(memory[byte_address]);
      		  else output_byte(memory[byte_address]);
  	       end

		   if(mem_read) byte_address[7:0] = byte_address[7:0] + 1;
		   else byte_address = byte_address + 1;
   	    end
	end
end
endtask

task read_page_dualio;
begin
	if(!status_reg[`WIP]) begin
		input_byte_dual(byte_address[23:16]);	
		input_byte_dual(byte_address[15:8]);
		input_byte_dual(byte_address[7:0]);
		input_mode_dual(mode_reg[7:2]);         
	    get_posclk_holdn;                       
      	
		while(!CSn) begin
			byte_address = byte_address & ADDRESS_MASK;
			output_byte_dual(memory[byte_address]);
			byte_address = byte_address + 1;
		end
	end
end
endtask

task read_page_quadio;
input [7:0] cmd;
integer x;
begin
    input_byte_quad(byte_address[23:16]);
	input_byte_quad(byte_address[15:8]);
	input_byte_quad(byte_address[7:0]);
	
	if(!status_reg[`WIP]) begin
	   case (cmd)
	       `CMD_READ_OCTAL_FAST_QUAD_IO : begin
                input_byte_quad(mode_reg[7:0]);              
                if(byte_address[3:0] != 0 && !CSn) begin
			        $display("WARNING: Error in Octal Word Read Quad I/O address input.");
		      	end
			end
			`CMD_READ_DATA_FAST_QUAD_IO : begin
                 input_byte_quad(mode_reg[7:0]);			     
         		 input_byte_quad(null_reg);
        	 	 input_byte_quad(null_reg);
			end
			`CMD_READ_WORD_FAST_QUAD_IO : begin
                input_byte_quad(mode_reg[7:0]);			     
		        input_byte_quad(null_reg);            
                if(byte_address[0] != 0 && !CSn) begin
			        $display("WARNING: Error in Word Read Quad I/O address input. A0 is non-zero!");
		        end
			end
			`CMD_READ_DATA_FAST_WRAP : begin
		       for(x = 0; x <= read_param_reg[5:4] && !CSn; x = x + 1) input_byte_quad(null_reg);
  	        end
	   endcase	   

	   while(!CSn) begin
			byte_address = byte_address & ADDRESS_MASK;
			output_byte_quad(memory[byte_address]);
			if(cmd == `CMD_READ_DATA_FAST_WRAP) begin
                case ({read_param_reg[1],read_param_reg[0]})		    
                   2'b00 : byte_address[2:0]  = byte_address[2:0] + 1;
                   2'b01 : byte_address[3:0] = byte_address[3:0] + 1;
                   2'b10 : byte_address[4:0] = byte_address[4:0] + 1;
                   2'b11 : byte_address[5:0] = byte_address[5:0] + 1;
                endcase
			end else if(!wrap_reg[4] && ((cmd == `CMD_READ_WORD_FAST_QUAD_IO) || (cmd == `CMD_READ_DATA_FAST_QUAD_IO))) begin
                case ({wrap_reg[6],wrap_reg[5]})		    
                   2'b00 : byte_address[2:0]  = byte_address[2:0] + 1;
                   2'b01 : byte_address[3:0] = byte_address[3:0] + 1;
                   2'b10 : byte_address[4:0] = byte_address[4:0] + 1;
                   2'b11 : byte_address[5:0] = byte_address[5:0] + 1;
                endcase
            end else byte_address = byte_address + 1;
		end
	end
end
endtask

task write_page;
input quadio;
integer x;
integer address;
begin
	if(!status_reg[`WIP]) begin
		input_byte(prog_byte_address[23:16]);
		input_byte(prog_byte_address[15:8]);
		input_byte(prog_byte_address[7:0]);
		prog_byte_address = prog_byte_address & ADDRESS_MASK;
		if(!write_protected(prog_byte_address) && !CSn)
		   fill_page_latch(quadio,prog_byte_address,0);
	end
end
endtask

task fill_page_latch;
input quadio;
input [31:0] prog_address;
input flag_secsi;
integer x;
integer address;
begin
  if(flag_secsi) begin
    address = (prog_address >> 4) - 31'h100;
    address[7:0] = 0;
  end else begin
    address = prog_address;
   	address[7:0] = 0;
  end

  for(x = 0; x < PAGESIZE; x=x+1) page_latch[x] = flag_secsi ? secsi[address+x] : memory[address+x];
	
  while(!CSn) begin
	   if(quadio) input_byte_quad(temp);
	   else input_byte(temp);
       
       if (!CSn) begin
		   page_latch[prog_address[7:0]] = temp;
		   if(flag_secsi) flag_prog_secsi_page = 1;
		   else flag_prog_page = 1;
		   prog_address[7:0] = prog_address[7:0] + 1;
       end
  end
end
endtask

task dump_mem;
integer x;
integer file;
begin
  file = $fopen(`MEM_FILENAME);
  $fwrite(file,"/* Contents of Memory Array */");
	for(x = 0; x < (NUM_PAGES * PAGESIZE); x=x+1) begin
	  if(x % 16) $fwrite(file,"%h ", memory[x]);
	  else $fwrite(file,"\n%h ", memory[x]);	    
  end		   
  $fclose(file);
end
endtask

always @(posedge flag_set_read_param) begin :set_read_param
	@(posedge CSn);
	if(flag_set_read_param == 1) begin
	   read_param_reg = read_param_reg_shadow;
	end
    flag_set_read_param = 0;	
end
 				
always @(posedge flag_reset) begin :reset
	@(posedge CSn);
	if((flag_reset == 1) && (flag_write_status_reg == 0)) begin
      flag_reset_condition = 1;
      #tRES1;                     	    
      chip_reset();
	end
	flag_reset = 0;
end

always @(posedge flag_power_up_exec) begin :power_up
	@(posedge CSn);
	if(flag_power_up_exec == 1) begin
		if(flag_power_up_sig_read == 1) #tRES2;
		else #tRES1;
        flag_power_down = 0;
		flag_power_up_exec = 0;
		flag_power_up_sig_read = 0;
		flag_suspend = 0;
	end
end

always @(posedge flag_power_down) begin :power_down
	@(posedge CSn);
	if(flag_power_down == 1) begin
		#tDP;
	end
end

always @(posedge flag_suspend) begin :erase_suspend
	@(posedge CSn);					              
	if(flag_suspend == 1) begin
	   status_reg[`SUS] = 1;
       wait_reset(20000);
       flag_suspend_enabled = 1'b1;
       status_reg[`WIP] = 0;
       status_reg[`WEL] = 0;
   end
end

always @(posedge flag_resume) begin :erase_resume
	@(posedge CSn);					              
	if(flag_resume == 1) begin
	   status_reg[`SUS] = 0;
	   flag_suspend_enabled = 1'b0;
	   flag_suspend = 1'b0;
	   flag_resume = 1'b0;
	   status_reg[`WEL] = 1;
	   status_reg[`WIP] = 1;
   end
end

always @(posedge flag_erase_sector) begin :erase_sector
integer x;
	@(posedge CSn);					               
	if(flag_erase_sector == 1) begin
		status_reg[`WIP] = 1;
        wait_reset_suspend(tSE);	
		for(x = 0; x < SECTORSIZE; x=x+1) memory[(byte_address[23:12] * SECTORSIZE) + x] = 8'hff;
		status_reg[`WIP] = 0;
		status_reg[`WEL] = 0;
	end
	flag_erase_sector = 0;
end

always @(posedge flag_erase_secsi_sector) begin :erase_secsi_sector
integer x;
	@(posedge CSn);					               
	if(flag_erase_secsi_sector == 1) begin
		status_reg[`WIP] = 1;
        case(byte_address[23:8])
          16'h10 : begin wait_reset_suspend(tSE); for(x = 0; x < PAGESIZE; x=x+1) secsi[x] = 8'hff; end     
          16'h20 : begin wait_reset_suspend(tSE); for(x = 0; x < PAGESIZE; x=x+1) secsi[x+PAGESIZE] = 8'hff; end
          16'h30 : begin wait_reset_suspend(tSE); for(x = 0; x < PAGESIZE; x=x+1) secsi[x+(PAGESIZE * 2)] = 8'hff; end
        endcase  
		status_reg[`WIP] = 0;
		status_reg[`WEL] = 0;
	end
	flag_erase_secsi_sector = 0;
end

always @(posedge flag_erase_block) begin :erase_block
integer x;
	@(posedge CSn);					                   
	if(flag_erase_block == 1) begin
		status_reg[`WIP] = 1;
		wait_reset_suspend(tBE2);
		for(x = 0; x < BLOCKSIZE; x=x+1) memory[(byte_address[23:16] * BLOCKSIZE) + x] = 8'hff;
        status_reg[`WIP] = 0;
		status_reg[`WEL] = 0;
	end
	flag_erase_block = 0;
end

always @(posedge flag_erase_half_block)	begin :erase_half_block
integer x;
	@(posedge CSn);					                  
	if(flag_erase_half_block == 1) begin
		status_reg[`WIP] = 1;
        wait_reset_suspend(tBE1);
		for(x = 0; x < HALFBLOCKSIZE; x=x+1) memory[(byte_address[23:15] * HALFBLOCKSIZE) + x] = 8'hff;
		status_reg[`WIP] = 0;
		status_reg[`WEL] = 0;
	end
	flag_erase_half_block = 0;
end

always @(posedge flag_erase_bulk) begin :erase_bulk
integer x;
	@(posedge CSn);			             
	if(flag_erase_bulk == 1) begin
		status_reg[`WIP] = 1;
		for(x = 0; x < 20; x=x+1) wait_reset(tCE_20);
		for(x = 0; x < PAGESIZE * NUM_PAGES; x=x+1) memory[x] = 8'hff;
		status_reg[`WIP] = 0;
		status_reg[`WEL] = 0;
	end
	flag_erase_bulk = 0;
end

always @(posedge flag_prog_page) begin :program_to_page
integer x;                         
	@(posedge CSn);						            
	begin
    	status_reg[`WIP] = 1;
        prog_byte_address[7:0] = 0;
        for(x = 0; x < PAGESIZE; x=x+1) begin
          memory[prog_byte_address+x] = page_latch[x] & memory[prog_byte_address+x];
          wait_reset_suspend(tPP / PAGESIZE);
    	end
		status_reg[`WIP] = 0;
    	status_reg[`WEL] = 0;
	end
	flag_prog_page = 0;
end

always @(posedge flag_prog_secsi_page) begin :program_to_secsi_page
integer x;                                
	@(posedge CSn);					       	            
	begin
    	status_reg[`WIP] = 1;
        prog_byte_address[7:0] = 0;
        case(prog_byte_address[23:8])
          16'h10 : begin
             for(x = 0; x < PAGESIZE; x=x+1) begin
                secsi[x] = page_latch[x] & secsi[x]; wait_reset_suspend(tPP / PAGESIZE);
         	 end
     	  end     
          16'h20 : begin
             for(x = 0; x < PAGESIZE; x=x+1) begin
                secsi[x+PAGESIZE] = page_latch[x] & secsi[x+PAGESIZE]; wait_reset_suspend(tPP / PAGESIZE);
         	 end
     	  end     
          16'h30 : begin
             for(x = 0; x < PAGESIZE; x=x+1) begin
                secsi[x+(PAGESIZE*2)] = page_latch[x] & secsi[x+(PAGESIZE*2)]; wait_reset_suspend(tPP / PAGESIZE);
         	 end
     	  end     
        endcase  
		status_reg[`WIP] = 0;
		status_reg[`WEL] = 0;
	end
	flag_prog_secsi_page = 0;
end

always @(posedge flag_write_status_reg)	begin :write_status_reg
	@(posedge CSn);						
	if(flag_write_status_reg == 1) begin
       status_reg[`WIP] = 1;
       status_reg[`QE] = status_reg_shadow[`QE];
       status_reg[`SRP1] = status_reg_shadow[`SRP1];
       status_reg[`SRP0] = status_reg_shadow[`SRP0];
       status_reg[`BP0] = status_reg_shadow[`BP0];
       status_reg[`BP1] = status_reg_shadow[`BP1];
	   status_reg[`BP2] = status_reg_shadow[`BP2];
       status_reg[`TB] = status_reg_shadow[`TB];	   
	   status_reg[`SEC] = status_reg_shadow[`SEC];
	   status_reg[`CMP] = status_reg_shadow[`CMP];
	   status_reg[`WPS] = status_reg_shadow[`WPS];
	   status_reg[`DRV0] = status_reg_shadow[`DRV0];
	   status_reg[`DRV1] =  status_reg_shadow[`DRV1];
	   status_reg[`HLD_RST] = status_reg_shadow[`HLD_RST];
	   
       status_reg[`LB1] = status_reg[`LB1] | status_reg_shadow[`LB1];
       status_reg[`LB2] = status_reg[`LB2] | status_reg_shadow[`LB2];
       status_reg[`LB3] = status_reg[`LB3] | status_reg_shadow[`LB3];

	   if(!flag_volatile_sr_write) begin
	      status_reg_otp[`QE] = status_reg_shadow[`QE];
  	      status_reg_otp[`SRP1] = status_reg_shadow[`SRP1];
  	      status_reg_otp[`SRP0] = status_reg_shadow[`SRP0];
  	      status_reg_otp[`BP0] = status_reg_shadow[`BP0];
  	      status_reg_otp[`BP1] = status_reg_shadow[`BP1];
	      status_reg_otp[`BP2] = status_reg_shadow[`BP2];
          status_reg_otp[`TB] = status_reg_shadow[`TB];
	      status_reg_otp[`SEC] = status_reg_shadow[`SEC];
	      status_reg_otp[`CMP] = status_reg_shadow[`CMP];
    	  status_reg_otp[`WPS] = status_reg_shadow[`WPS];
	      status_reg_otp[`DRV0] = status_reg_shadow[`DRV0];
	      status_reg_otp[`DRV1] =  status_reg_shadow[`DRV1];
	      status_reg_otp[`HLD_RST] = status_reg_shadow[`HLD_RST];
          status_reg_otp[`LB1] = status_reg[`LB1] | status_reg_shadow[`LB1];
          status_reg_otp[`LB2] = status_reg[`LB2] | status_reg_shadow[`LB2];
          status_reg_otp[`LB3] = status_reg[`LB3] | status_reg_shadow[`LB3];
       end   
      
       if(status_reg[`QE] == 0) flag_qpi_mode = 0;
         
	   if(status_reg[`WEL]) wait_reset(tW);
	   status_reg[`WIP] = 0;
	   status_reg[`WEL] = 0;
	   flag_volatile_sr_write = 0;
	   flag_write_status_reg = 0;
   end
end

endmodule 
/* verilator lint_on VARHIDDEN */
/* verilator lint_on CASEINCOMPLETE */
/* verilator lint_on BLKSEQ */
