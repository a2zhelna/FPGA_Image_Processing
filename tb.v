`timescale 1ps/1ps

module tb();

reg reset;
reg clock;
reg proc_clk;
reg unproc_clk;
reg valid;
reg [7:0] raw_byte;
reg out_bit;
wire in_bit;
wire proc_rx_ready;
wire proc_data_ready;
reg [7:0] processed_pixel;
reg row_sent;
integer file1, file2, i, j, k, n;

// File Specifications
`define WIDTH 200			//# of pixels
`define HEIGHT 250			//# of pixels
`define DEPTH 3				//How many bytes per pixel
`define TOTAL_SIZE 150138	//In Bytes

// `define WIDTH 10			//# of pixels
// `define HEIGHT 10			//# of pixels
// `define DEPTH 3				//How many bytes per pixel
// `define TOTAL_SIZE 458	//In Bytes

ImageProcTop dut(
	.reset(reset),
	.clock(clock),
	.proc_clk(proc_clk),
	.unproc_clk(unproc_clk),
	.data_in(out_bit),
	.valid(valid),
	
	.rx_ready(proc_rx_ready),
	.tx_ready(proc_data_ready),
	.data_out(in_bit)
	);
	
//wire pxl_data = dut.ImageProcTop.pxl;	//This is how you can view internal signals in ModelSim


always #10 clock = ~clock;

reg [7:0] test_raw_buf_buf [2:0];

integer padded_bytes; 

initial begin
	clock = 0;
	row_sent = 1;
	reset = 1;
	unproc_clk <= 1;
	proc_clk <= 1;
	valid <= 0;
	#100;
	reset = 0;
	#100;
	reset = 1;
	#100;
	file1 = $fopen("Birdy.bmp", "rb");
	file2 = $fopen("FilteredImg.bmp","wb");
	
	if (file1)  	$display("File was opened successfully : %0d", file1);
   	else     		$display("File was NOT opened successfully : %0d", file1);
	
	padded_bytes = (4-((`DEPTH*`WIDTH)%4))%4;		//The amount of 00 bytes added into bmp file's row

	for(i=0;i<(`TOTAL_SIZE-((`WIDTH*`DEPTH + padded_bytes)*`HEIGHT));i=i+1) begin		//Get bmp header
		$fscanf(file1,"%c",raw_byte);		//%c - scan byte by byte
		$fwrite(file2,"%c",raw_byte);
	end
	
	for(i=0;i<`HEIGHT;i=i+1) begin
		wait (proc_rx_ready)
		valid = 1;
		for(j=0;j<(`DEPTH*`WIDTH);j=j+1) begin
			$fscanf(file1,"%c",raw_byte);
			serializePixel();
			// $write("%h ",raw_byte);	//Data is stored starting from the bottom row
			// 							//Each pixel's data is adjacent in BGR order
		end
		for(j=0;j<padded_bytes;j=j+1) begin
			$fscanf(file1,"%c",raw_byte);		//Ensure padded bytes aren't sent
		end

		#20;		//Small delay 
		valid = 0;
		#20;
	end

end

initial begin
	//Get all data from processor	(-2 because using 3x3 kernel removes 2 rows)
	for(n=0;n<`HEIGHT-2;n=n+1) begin
		for(k=0;k<(`DEPTH*`WIDTH-6);k=k+1) begin		// -6 because using 3x3 kernel removes 2 pixels (6 bytes)
			deserializePixel();
			$fwrite(file2,"%c",processed_pixel);
		end
		for(k=0;k<6;k=k+1) begin
			$fwrite(file2,"%c",0);		//Add removed columns to bmp file 
		end
		for(k=0;k<padded_bytes;k=k+1) begin
			$fwrite(file2,"%c",0);		//Add byte padding to bmp file 
		end
	end
	for(n=0;n<2;n=n+1) begin
		for(k=0;k<`DEPTH*`WIDTH*2;k=k+1) begin
			$fwrite(file2,"%c",0);		//Add removed rows to bmp file
		end
		for(k=0;k<padded_bytes;k=k+1) begin
			$fwrite(file2,"%c",0);		//Add byte padding to bmp file 
		end
	end

	$fclose(file1);
	$fclose(file2);
	$stop;
end

integer count;

task serializePixel;
	begin : SERIALIZE
		count = 0;
		repeat(8) begin
			@(negedge clock)
			unproc_clk <= 0;
			out_bit <= raw_byte[7-count];
			count <= count + 1;
			@(posedge clock)
			unproc_clk <= 1;
		end
	end
endtask

task deserializePixel;
	begin
		wait(proc_data_ready);
		processed_pixel = 0;
		repeat(8) begin
			@(negedge clock)
			proc_clk = 0;
			@(posedge clock)
			proc_clk = 1;
			processed_pixel = processed_pixel << 1;
			processed_pixel[0] = in_bit;
		end
	end
endtask

endmodule