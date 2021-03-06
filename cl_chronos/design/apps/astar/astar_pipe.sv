/** $lic$
 * Copyright (C) 2014-2019 by Massachusetts Institute of Technology
 *
 * This file is part of the Chronos FPGA Acceleration Framework.
 *
 * Chronos is free software; you can redistribute it and/or modify it under the
 * terms of the GNU General Public License as published by the Free Software
 * Foundation, version 2.
 *
 * If you use this framework in your research, we request that you reference
 * the Chronos paper ("Chronos: Efficient Speculative Parallelism for
 * Accelerators", Abeydeera and Sanchez, ASPLOS-25, March 2020), and that
 * you send us a citation of your work.
 *
 * Chronos is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program. If not, see <http://www.gnu.org/licenses/>.
 */



import chronos::*;
module astar_rw
#(
   parameter TILE_ID=0
) (

   input clk,
   input rstn,

   input logic             task_in_valid,
   output logic            task_in_ready,

   input task_t            in_task, 
   input rw_data_t          in_data,
   input cq_slice_slot_t   in_cq_slot,
  
   output logic            wvalid,
   output logic [31:0]     waddr,
   output ro_data_t           wdata,
   output logic [2:0]      wsize,

   output logic            out_valid,
   output task_t           out_task,
   output ro_data_t           out_data,
   output logic            out_task_rw,

   output logic            sched_task_valid,
   input logic             sched_task_ready,

   reg_bus_t               reg_bus

);

logic [31:0] base_rw_addr;
logic skip_type_1_rw;
logic skip_type_1_ro;
assign task_in_ready = sched_task_valid & sched_task_ready;
assign sched_task_valid = task_in_valid;

assign out_task_rw = 1'b0;
assign wsize = 2;

logic [31:0] gScore;
assign gScore = in_task.ts;

always_comb begin 
   wvalid = 0;
   wdata = 'x;
   waddr = base_rw_addr + ( in_task.object << 2) ;
   wdata = in_task.ts;
   out_valid = 1'b0;

   out_task = in_task;

   if (task_in_valid) begin
      if (in_task.ttype == 0) begin
         if( (NO_ROLLBACK & ( gScore < in_data)) |
             (!NO_ROLLBACK &  (in_data == '1) ) ) begin 
            wvalid = 1'b1;
            out_valid = 1'b1;
         end
      end else if (in_task.ttype == 1) begin // queue_vertex task
         if (skip_type_1_rw & (gScore >= in_data)) begin
            out_valid = 1'b0;
         end else begin
            out_valid = 1'b1; 
            if (skip_type_1_ro) begin
               out_task.args[63:32] = in_data; // if new dist is larger than this value, do not enqueue ttype 0
            end
         end
      end else if (in_task.ttype == TASK_TYPE_TERMINATE) begin
         // nothing
      end
   end
end

always_ff @(posedge clk) begin
   if (!rstn) begin
      base_rw_addr <= 0;
      skip_type_1_rw <= 1;
      skip_type_1_ro <= 1;
   end else begin
      if (reg_bus.wvalid) begin
         case (reg_bus.waddr) 
            8'd20 : base_rw_addr <= {reg_bus.wdata[29:0], 2'b00};
            8'd52 : {skip_type_1_rw, skip_type_1_ro} <= reg_bus.wdata[1:0];
         endcase
      end
   end
end

         
`ifdef XILINX_SIMULATOR
   logic [63:0] cycle;
   always_ff @(posedge clk) begin
      if (!rstn) cycle <=0;
      else cycle <= cycle + 1;
      if (task_in_valid & task_in_ready) begin
         $display("[%5d] [rob-%2d] [write_rw] [%2d] ts:%8d object:%4d type:%1x",
            cycle, TILE_ID, in_cq_slot,
            in_task.ts, in_task.object, in_task.ttype) ;
      end
   end 
`endif


endmodule

module astar_ro
#(
   parameter SUBTYPE=0,
   parameter TILE_ID=0
) (

   input clk,
   input rstn,

   input logic             task_in_valid,
   output logic            task_in_ready,

   input task_t            in_task, 
   input ro_data_t            in_data,
   input byte_t            in_word_id,
   input cq_slice_slot_t   in_cq_slot,
  
   output cq_slice_slot_t  out_cq_slot,
   
   output logic            arvalid,
   output logic [31:0]     araddr,
   output logic [2:0]      arsize,
   output logic [7:0]      arlen,
   output task_t           resp_task, //each mem resp will create a new task with this parameters
   output subtype_t        resp_subtype,
   output logic            resp_mark_last, // mark the last resp task as last

   output logic            out_valid,
   output task_t           out_task,
   output subtype_t        out_subtype,

   output logic            out_task_is_child, // if 0, out_task is re-enqueued back to a FIFO, else sent to CM

   output logic            sched_task_valid,
   input logic             sched_task_ready,

   output logic [31:0]     log_output,


   reg_bus_t               reg_bus

);

logic [31:0] offset_base_addr;
logic [31:0] neighbors_base_addr;
logic [31:0] latlon_base_addr;

logic [31:0] target_lat, target_lon;
logic [31:0] targetNode;

logic skip_type_1_ro;

logic [31:0] astar_dist;
logic astar_dist_out_valid;

typedef struct packed {
   task_t          in_task;
   cq_slice_slot_t in_cq_slot;
} fifo_word_t;


assign resp_task = in_task;

generate 
if (SUBTYPE == 0) begin

   assign sched_task_valid = task_in_valid;
   assign task_in_ready = sched_task_ready;
   assign out_cq_slot = in_cq_slot;
   always_comb begin
      araddr = 'x;
      arsize = 2;
      arlen = 0;
      arvalid = 1'b0;
      out_valid = 1'b0;
      resp_mark_last = 1'b0;
      out_task = in_task;
      out_task_is_child = 1'b1;
      resp_subtype = 'x;
      
      if (task_in_valid) begin
         if (in_task.ttype == 0) begin
            if (in_task.object == targetNode) begin
               araddr = offset_base_addr;
               arsize = 2;
               arvalid = 1'b1;
               arlen = (N_TILES-1);
               resp_subtype = 1;
            end else begin
               araddr = offset_base_addr + (in_task.object <<  2);
               arsize = 3;
               arvalid = 1'b1;
               arlen = 0;
               resp_subtype = 1;
            end
         end else begin
            araddr = latlon_base_addr + (in_task.object << 3);
            arvalid = 1'b1;
            arsize = 3;
            arlen = 0;
            resp_subtype = 3;
            resp_mark_last = 1'b1;
         end
      end
   end

end else if (SUBTYPE == 1) begin
   assign sched_task_valid = task_in_valid;
   assign task_in_ready = sched_task_ready;
   assign out_cq_slot = in_cq_slot;
   always_comb begin
      araddr = 'x;
      arsize = 2;
      arlen = 0;
      arvalid = 1'b0;
      out_valid = 1'b0;
      resp_mark_last = 1'b0;
      out_task = in_task;
      out_task_is_child = 1'b1;
      resp_subtype = 'x;

      if (task_in_valid) begin
         if (in_task.ttype == 0) begin
            if (in_task.object == targetNode) begin
               out_valid = 1'b1;
               out_task.ttype = TASK_TYPE_TERMINATE;
               out_task.object = in_word_id << 4; // only works with TSB_HASH_KEY=0 
               out_task_is_child = 1'b1;
            end else begin
               araddr = neighbors_base_addr + (in_data[31:0] <<  3);
               arvalid = (in_data[63:32] != in_data[31:0]);
               arsize = 3;
               arlen = (in_data[63:32] - in_data[31:0])-1;
               resp_subtype = 2;
               resp_mark_last = 1'b1;
            end
         end
      end
   end

end else if (SUBTYPE == 2) begin

   assign sched_task_valid = task_in_valid;
   assign task_in_ready = sched_task_ready;
   assign out_cq_slot = in_cq_slot;
   always_comb begin
      araddr = 'x;
      arsize = 2;
      arlen = 0;
      arvalid = 1'b0;
      out_valid = 1'b0;
      resp_mark_last = 1'b0;
      out_task = in_task;
      out_task_is_child = 1'b1;
      resp_subtype = 'x;

      if (task_in_valid) begin
         if (in_task.ttype == 0) begin
            out_valid = 1'b1;
            out_task.ttype = 1;
            out_task.object = in_data[31:0];
            out_task.args[31:0] = in_task.args[31:0] + in_data[63:32];
            out_task.args[63:32] = in_task.object;
            out_task.ts = in_task.ts;
            out_task_is_child = 1'b1;
         end
      end
   end

end else if (SUBTYPE == 3) begin

   assign arvalid = 1'b0;

   logic dist_fifo_full, dist_fifo_empty;
   logic in_flight_fifo_full, in_flight_fifo_empty;
   task_t in_flight_fifo_out;
   logic [31:0] dist_fifo_out;

   assign sched_task_valid = !in_flight_fifo_empty & !dist_fifo_empty;
  
   assign out_subtype = 0;
   assign out_task_is_child = 1'b1;
   always_comb begin
      out_task = in_flight_fifo_out;
      out_task.ttype = 0;
      out_valid = 1'b0;
      if ( (dist_fifo_out + in_flight_fifo_out.args[31:0]) < in_flight_fifo_out.ts) begin
         out_task.ts = in_flight_fifo_out.ts;
      end else begin
         out_task.ts = dist_fifo_out + in_flight_fifo_out.args[31:0];
      end
      if (sched_task_valid) begin
         if (skip_type_1_ro) begin
            out_valid = out_task.ts < in_flight_fifo_out.args[63:32];
         end else begin
            out_valid = 1'b1;
         end
      end

   end

   logic reg_valid;
   assign task_in_ready = task_in_valid & ( !reg_valid | ap_ready) & !in_flight_fifo_full;
   logic ap_ready;
   logic [63:0] reg_in_data;
   always_ff @(posedge clk) begin
      if (!rstn) begin
         reg_valid <= 1'b0;
      end else begin
         if (task_in_valid & task_in_ready) begin
            reg_valid <= 1'b1;
            reg_in_data <= in_data;
         end else if (ap_ready) begin
            reg_valid <= 1'b0;
         end
      end
   end

   logic [31:0] srcLat, srcLon;

   always_comb begin
      srcLat = reg_in_data[31:0];
      srcLon = reg_in_data[63:32];
   end   

   cq_slice_slot_t in_flight_fifo_out_cq_slot;
   assign out_cq_slot = in_flight_fifo_out_cq_slot;
   
   logic[7:0] in_flight_fifo_size;
   logic[7:0] dist_fifo_size;

   fifo #(
      .WIDTH( $bits(in_cq_slot)+ $bits(in_task )),
      .LOG_DEPTH(6)
   ) IN_FLIGHT_FIFO (
      .clk(clk),
      .rstn(rstn),
      
      .wr_en(task_in_valid & task_in_ready & (in_task.ttype==1)),
      .rd_en(sched_task_valid & sched_task_ready),
      .wr_data({in_cq_slot, in_task}),
      .rd_data({in_flight_fifo_out_cq_slot, in_flight_fifo_out}),

      .full(in_flight_fifo_full),
      .empty(in_flight_fifo_empty),
      .size(in_flight_fifo_size)
   );
   
   fifo #(
      .WIDTH( 32 ),
      .LOG_DEPTH(6)
   ) DIST_FIFO (
      .clk(clk),
      .rstn(rstn),
      
      .wr_en(astar_dist_out_valid),
      .rd_en(sched_task_valid & sched_task_ready),
      .wr_data(astar_dist),
      .rd_data(dist_fifo_out),

      .full(dist_fifo_full),
      .empty(dist_fifo_empty),
      .size(dist_fifo_size)
   );

   astar_dist DIST (
           .ap_clk (clk),
           .ap_rst (~rstn),
           .ap_start (reg_valid),
           .ap_done  (),
           .ap_idle  (),
           .ap_ready (ap_ready),
           .src_lat_V  (srcLat),
           .src_lon_V  (srcLon),
           .dst_lat_V  (target_lat),
           .dst_lon_V  (target_lon),
           .out_r      (astar_dist),
           .out_r_ap_vld (astar_dist_out_valid)
   );

   assign log_output[17:0] = dist_fifo_out;
   assign log_output[31:25] = in_flight_fifo_size; 
   assign log_output[24:18] = dist_fifo_size; 

end
endgenerate


always_ff @(posedge clk) begin
   if (!rstn) begin
      skip_type_1_ro <= 1'b1;
   end else begin
      if (reg_bus.wvalid) begin
         case (reg_bus.waddr)
            8'd12 : offset_base_addr <= (reg_bus.wdata << 2);
            8'd16 : neighbors_base_addr <= (reg_bus.wdata << 2);
            8'd24 : latlon_base_addr <= (reg_bus.wdata << 2);
            8'd32 : targetNode <= reg_bus.wdata; 
            8'd44 : target_lat <= reg_bus.wdata; 
            8'd48 : target_lon <= reg_bus.wdata; 
            8'd52 : skip_type_1_ro <= reg_bus.wdata[0];
         endcase
      end
   end
end

`ifdef XILINX_SIMULATOR
   logic [63:0] cycle;
   always_ff @(posedge clk) begin
      if (!rstn) cycle <=0;
      else cycle <= cycle + 1;
      if (task_in_valid & task_in_ready) begin
         $display("[%5d] [rob-%2d] [ro %2d] [%3d] ts:%8d object:%4d data:(%5d %5d)",
            cycle, TILE_ID, SUBTYPE, in_cq_slot,
            in_task.ts, in_task.object, in_data[63:32], in_data[31:0] ) ;
      end
   end 
`endif


endmodule
