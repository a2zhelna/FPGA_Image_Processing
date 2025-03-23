module ImageProcTop(
	input reset,
	input clock,
	input unproc_clk,
	input proc_clk,
	input data_in,
	input valid,	//0 when data is being sent
	
	output reg rx_ready,
	output reg tx_ready,
	output reg data_out
);

// -- Kernel
`define KERNEL_RES 8
`define KERNEL_DIM 3			//The width (or height) of the kernel
`define KERNEL_SIZE_BITS 4 		//The amount of bits required to represent the size of the kernel 
								//(for a 3X3 kernel, there are 9 cells, which is a 4 bit value)
								//This is useful for figuring out the size of the unbounded convolution result register
reg signed [(`KERNEL_RES-1):0] kernel [(`KERNEL_DIM-1):0] [(`KERNEL_DIM-1):0];
reg signed [((`KERNEL_RES+8+`KERNEL_SIZE_BITS)-1):0] proc_result_unbounded;		//Ensure result register is large enough to do kernel operations
																//Total bits = kernel_res + pixel_res + 9
reg [7:0] proc_result;	
reg signed [8:0] kernel_operand [8:0];	//Takes 8-bit values from input buffer, and casts them to 9-bit signed values
										//to allow valid, signed multiplication

// --- IO Registers
reg [9:0] pxl_count;		//The amount of pixels stored in the previously filled buffer
reg [1:0] filled_buf_count;
reg processing_complete;

// --- State Machine states
`define RX_WAIT_STATE 0
`define RX_GO_STATE 1
reg receiver_state = `RX_WAIT_STATE;

`define PROC_WAIT_STATE 0
`define PROC_GO_STATE 1
reg processor_state = `PROC_WAIT_STATE;

//Loop variables
integer a,b,c;

// ---- FSMs
reg [1:0] rows_filled;
reg [1:0] inbuf_ptr;
reg begin_processing;
reg enable_rx;
reg trigger_proc_pulse;

reg [11:0] pixel_num;
reg [11:0] in_pxl_pntr;
reg [2:0] in_bit_pntr;

reg tx_complete;

always @(posedge clock) begin
	if (!reset) begin
		receiver_state <= `RX_WAIT_STATE;
		enable_rx <= 0;
		begin_processing <= 0;
		inbuf_ptr <= 0;
		rx_ready <= 0;
		rows_filled <= 0;
		pixel_num <= 0;

		// the "s" is the signed literal notation
		kernel[0][0] <=  8'sd0;
		kernel[0][1] <= -8'sd1;
		kernel[0][2] <=  8'sd0;
		kernel[1][0] <= -8'sd1;
		kernel[1][1] <=  8'sd5;
		kernel[1][2] <= -8'sd1;
		kernel[2][0] <=  8'sd0;
		kernel[2][1] <= -8'sd1;
		kernel[2][2] <=  8'sd0;
	end
	else begin
		case(receiver_state)
			`RX_WAIT_STATE: begin 
				if (valid == 1) begin
					receiver_state <= `RX_GO_STATE;
					enable_rx <= 1;
					begin_processing <= 0;
					rx_ready <= 1;
				end
				else begin
					receiver_state <= `RX_WAIT_STATE;
					begin_processing <= 0;
					rx_ready <= 1;
				end
			end
			`RX_GO_STATE: begin
				if ((valid == 0) && (rows_filled<2)) begin
					receiver_state <= `RX_WAIT_STATE;
					enable_rx <= 0;
					rows_filled <= rows_filled + 1;
					if (rows_filled==0) begin
						pixel_num <= in_pxl_pntr;	//Get the amount of pixels in the first-received row
					end
					inbuf_ptr <= inbuf_ptr + 1;	//Change which buffer gets filled up next
												//Also used to let processor know what row(s) to process
				end
				else if ((valid == 0) && (rows_filled >= 2) && tx_complete) begin
					receiver_state <= `RX_WAIT_STATE;
					enable_rx <= 0;
					begin_processing <= 1;
					inbuf_ptr <= inbuf_ptr + 1;
				end
				else if (valid == 0) begin
					rx_ready <= 0;		//Can't receive next row of data until data has been processed and tx'd
				end
				else begin
					//Do nothing
				end
			end
		endcase
	end
end



reg enable_tx;

always @(posedge clock) begin
	if (!reset) begin
		receiver_state <= `PROC_WAIT_STATE;
		enable_tx <= 0;
	end
	else begin
		case(processor_state)
			`PROC_WAIT_STATE: begin 
				if (begin_processing == 1) begin
					processor_state <= `PROC_GO_STATE;
					enable_tx <= 1;
				end
				else begin
					processor_state <= `PROC_WAIT_STATE;
				end
			end
			`PROC_GO_STATE: begin
				if (tx_complete == 1) begin
					processor_state <= `PROC_WAIT_STATE;
					enable_tx <= 0;
				end
			 	else begin
					processor_state <= `PROC_GO_STATE;
				end
			end
		endcase
	end
end



// --- Data Receiving Logic
reg [7:0] inbuf [3:0][2819:0];

always @(posedge unproc_clk or negedge enable_rx or negedge reset) begin
	if (!reset) begin
		//Clear input buffers
		for(a=0;a<4;a=a+1) begin
			for(b=0;b<2820;b=b+1) begin
				inbuf[a][b] <= 0;
			end
		end
		in_pxl_pntr <= 0;
		in_bit_pntr <= 0;
	end
	if (enable_rx == 0) begin
		in_pxl_pntr <= 0;
		in_bit_pntr <= 0;
	end
	else begin
		inbuf[inbuf_ptr][in_pxl_pntr][7-in_bit_pntr] <= data_in;
		in_bit_pntr <= in_bit_pntr + 1;
		if (in_bit_pntr == 7) begin
			in_pxl_pntr <= in_pxl_pntr + 1;
		end
	end
end

// --- Data Processing Logic
reg [11:0] proc_idx;			// Byte that is being processed
reg [7:0] outbuf [2819:0];		//Buffer storing processed bytes ready to be outputted

always @(*) begin 
	kernel_operand[0] = {1'b0, inbuf[(inbuf_ptr+3)%4][proc_idx]};
	kernel_operand[1] = {1'b0, inbuf[(inbuf_ptr+3)%4][proc_idx+3]};
	kernel_operand[2] = {1'b0, inbuf[(inbuf_ptr+3)%4][proc_idx+6]};  
	kernel_operand[3] = {1'b0, inbuf[(inbuf_ptr+2)%4][proc_idx]};    
	kernel_operand[4] = {1'b0, inbuf[(inbuf_ptr+2)%4][proc_idx+3]}; 
	kernel_operand[5] = {1'b0, inbuf[(inbuf_ptr+2)%4][proc_idx+6]};
	kernel_operand[6] = {1'b0, inbuf[(inbuf_ptr+1)%4][proc_idx]};  
	kernel_operand[7] = {1'b0, inbuf[(inbuf_ptr+1)%4][proc_idx+3]};
	kernel_operand[8] = {1'b0, inbuf[(inbuf_ptr+1)%4][proc_idx+6]};
end

always @(*) begin
    proc_result_unbounded = (kernel_operand[0]  * kernel[0][0]) +
							(kernel_operand[1]  * kernel[0][1]) +
							(kernel_operand[2]  * kernel[0][2]) +
							(kernel_operand[3]  * kernel[1][0]) +
							(kernel_operand[4]  * kernel[1][1]) +
							(kernel_operand[5]  * kernel[1][2]) +
							(kernel_operand[6]  * kernel[2][0]) +
							(kernel_operand[7]  * kernel[2][1]) +
							(kernel_operand[8]  * kernel[2][2]);
end

//Bound the convolution result
always @(*) begin
	if (proc_result_unbounded > 255) begin
		proc_result = 255;
	end
	else if (proc_result_unbounded < 0) begin
		proc_result = 0;
	end
	else begin
		proc_result = proc_result_unbounded;
	end
end

always @(posedge clock or negedge enable_tx) begin
	if ((!reset) || (enable_tx == 0)) begin
		//Clear output buffer
		for (c=0;c<2820;c=c+1) begin
			outbuf[c] <= 0;
		end
		proc_idx <= 0;
	end
	else begin

		// DATA PROCESSING:
		//Note that when you have a 3x3 kernel, the output has two less pixels (`KERNEL_DIM-1). 
		//Because each pixel has 3 columns, multiply by 3 (3*(`KERNEL_DIM-1))
		if (proc_idx < pixel_num-(3*(`KERNEL_DIM-1))) begin
			outbuf[proc_idx] <= proc_result;
			proc_idx <= proc_idx + 1;
		end
		else begin
			//Do nothing
		end
	end
end

// --- Data Transmission Logic 

reg [11:0] tx_idx;
reg [2:0] tx_bit_idx;

always @(negedge proc_clk or negedge enable_rx or negedge reset) begin
	if ((!reset) || (enable_tx == 0)) begin
		tx_idx <= 0;
		tx_bit_idx <= 0;
	end
	else begin
		if (tx_ready) begin		//If there's data that must be sent
			data_out <= outbuf[tx_idx][7-tx_bit_idx];		//Uninitialized (concern?)
			tx_bit_idx <= tx_bit_idx + 1;
			if (tx_bit_idx == 7) begin
				tx_idx <= tx_idx + 1;
			end
		end	
	end
end

//Combinational circuit that finds out when there's output data available
always @(*) begin
	tx_ready = 0;
	tx_complete = 1;
	if (enable_tx && reset) begin
		tx_complete = 0;
		if ( (proc_idx > 0) && (tx_idx < proc_idx) && (tx_idx < (pixel_num-(3*(`KERNEL_DIM-1)))) ) begin
			tx_ready = 1;
		end
		else if ( (proc_idx > 0) && (tx_idx == proc_idx) && (tx_idx < (pixel_num-(3*(`KERNEL_DIM-1)))) ) begin
			tx_ready = 0;		//no data available to send - caught up to the buffer tail
		end
		else if ( (proc_idx > 0) && (tx_idx == (pixel_num-(3*(`KERNEL_DIM-1)))) ) begin
			tx_complete = 1;
		end
	end
end


 

endmodule
